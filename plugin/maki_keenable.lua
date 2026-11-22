local MAX_RESULTS = 10
local SNIPPET_MAX_LENGTH = 500
local MAX_CHARS = 20000
local FETCH_TIMEOUT_SECS = 60

local API_BASE = "https://api.keenable.ai"
local DECODE_OPTS = { luanil = { object = true, array = true } }

local truncate = require("maki.truncate")
local output_limits = require("maki.output_limits")

local function nonblank(s)
  return type(s) == "string" and s:match("%S") ~= nil
end

local function fail(msg)
  return { llm_output = "error: " .. msg, is_error = true }
end

local function ok(text, ctx)
  local max_lines, max_bytes = output_limits.resolve({}, ctx)
  return { llm_output = truncate(text, max_lines, max_bytes), format = "markdown" }
end

local function encode(s)
  return (s:gsub("[^%w%-_.~]", function(c)
    return ("%%%02X"):format(c:byte())
  end))
end

local function describe_error(res, keyed)
  local data = maki.json.decode(res.body, DECODE_OPTS)
  if type(data) ~= "table" then
    return ("Keenable HTTP %d: %s"):format(res.status, res.body:sub(1, 200))
  end
  local msg = ("Keenable HTTP %d: %s"):format(res.status, tostring(data.message or data.error))
  if data.code then
    msg = msg .. " (" .. tostring(data.code) .. ")"
  end
  if data.retryable ~= nil then
    msg = msg .. (data.retryable and ". Retryable." or ". Not retryable.")
  end
  if res.status == 429 and not keyed then
    msg = msg .. " Set KEENABLE_API_KEY to raise the limit."
  end
  return msg
end

-- Without a key, calls go to the keyless /public twin of each endpoint.
local function call(path, query, req, ctx)
  local key = maki.uv.os_getenv("KEENABLE_API_KEY")
  key = nonblank(key) and key:match("^%s*(.-)%s*$") or nil
  req.headers["X-Keenable-Title"] = "maki"
  req.headers["X-Keenable-Session-Id"] = ctx:session_id()
  if key then
    req.headers["X-API-Key"] = key
  else
    path = path .. "/public"
  end
  req.retry = 0
  local res, err = maki.net.request(API_BASE .. path .. query, req)
  if not res then
    return nil, err
  end
  if res.status < 200 or res.status >= 300 then
    return nil, describe_error(res, key ~= nil)
  end
  local data = maki.json.decode(res.body, DECODE_OPTS)
  if type(data) ~= "table" then
    return nil, "Keenable returned invalid JSON"
  end
  return data
end

local function render_search(results)
  local out, seen, n = {}, {}, 0
  for _, r in ipairs(results or {}) do
    if nonblank(r.url) and not seen[r.url] then
      seen[r.url] = true
      n = n + 1
      local head = ("[%d] %s (%s)"):format(n, nonblank(r.title) and r.title or r.url, r.url)
      if nonblank(r.published_at) then
        head = head .. " - published " .. r.published_at:sub(1, 10)
      end
      out[#out + 1] = nonblank(r.snippet) and head .. "\n" .. r.snippet or head
    end
  end
  if n == 0 then
    return "No results found."
  end
  return table.concat(out, "\n\n")
end

-- Badge images and empty anchor links cost tokens and carry nothing.
local function strip_images(md)
  return (md:gsub("!%[[^%]]*%]%([^%)]*%)", ""):gsub("%[%]%([^%)]*%)", ""))
end

local function render_page(page)
  local out = {}
  if nonblank(page.title) then
    out[#out + 1] = "# " .. page.title
  end
  out[#out + 1] = page.url
  if nonblank(page.published_at) then
    out[#out + 1] = "Published: " .. page.published_at:sub(1, 10)
  end
  out[#out + 1] = ""
  out[#out + 1] = strip_images(page.content or "")
  if page.truncated and page.total_chars then
    out[#out + 1] = ("\n[cut at %d of %d chars; call again with prompt to extract a part]"):format(
      MAX_CHARS,
      page.total_chars
    )
  end
  return table.concat(out, "\n")
end

maki.api.register_tool({
  name = "web_search",
  kind = "search",
  permission = "net",
  description = [[Search the web for current information: documentation, release notes, error messages, and anything after your training cutoff. Returns ranked results with title, URL, publish date, and a page excerpt that often answers the question.

Describe the page you want in plain words, not keywords. Read promising results in full with web_fetch.]],
  schema = {
    type = "object",
    properties = {
      query = {
        type = "string",
        description = "The ideal page, described in plain words, e.g. 'official migration guide from Vite 6 to Vite 7'.",
        required = true,
      },
      site = { type = "string", description = "Optional. Only results from this site, e.g. 'docs.rs'." },
      published_after = {
        type = "string",
        description = "Optional. Only pages published after this date (YYYY-MM-DD) or offset such as '30d'. Drops pages with no known date.",
      },
    },
  },
  header = function(input)
    return input.query
  end,
  handler = function(input, ctx)
    if not nonblank(input.query) then
      return fail("query is required")
    end
    local body, err = maki.json.encode({
      query = input.query,
      site = nonblank(input.site) and input.site or nil,
      published_after = nonblank(input.published_after) and input.published_after or nil,
      max_results = MAX_RESULTS,
      snippet_max_length = SNIPPET_MAX_LENGTH,
      disable_cards = true,
    })
    if not body then
      return fail("failed to encode request: " .. tostring(err))
    end
    local data, req_err = call("/v1/search", "", {
      method = "POST",
      headers = { ["Content-Type"] = "application/json" },
      body = body,
    }, ctx)
    if not data then
      return fail(req_err)
    end
    return ok(render_search(data.results), ctx)
  end,
})

maki.api.register_tool({
  name = "web_fetch",
  kind = "read",
  permission = "net",
  description = [[Fetch a web page and return its current content as clean markdown, without navigation or ads. Use it to read a web_search result or a URL from the user.

Long pages are cut at 20,000 characters. Pass prompt to get back only the part you need.]],
  schema = {
    type = "object",
    properties = {
      url = { type = "string", description = "The http(s) URL to read.", required = true },
      prompt = {
        type = "string",
        description = "Optional. What to extract, e.g. 'List the breaking changes'. Returns only that instead of the whole page.",
      },
    },
  },
  header = function(input)
    return input.url
  end,
  handler = function(input, ctx)
    if not nonblank(input.url) or not input.url:match("^https?://") then
      return fail("url must be an http(s) URL")
    end
    local query = ("?url=%s&live=true&max_chars=%d"):format(encode(input.url), MAX_CHARS)
    if nonblank(input.prompt) then
      query = query .. "&prompt=" .. encode(input.prompt)
    end
    local data, err = call("/v1/fetch", query, {
      headers = { Accept = "application/json" },
      timeout = FETCH_TIMEOUT_SECS,
    }, ctx)
    if not data then
      return fail(err)
    end
    if not nonblank(data.url) then
      data.url = input.url
    end
    return ok(render_page(data), ctx)
  end,
})
