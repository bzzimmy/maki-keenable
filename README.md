<h1><img src="assets/keenable-logo.png" alt="Keenable" width="40" align="absmiddle"> maki-keenable</h1>

Context-efficient web access for [maki](https://github.com/tontinton/maki),
backed by the [Keenable API](https://keenable.ai). Two tools replace the
built-in web tools: search returns ranked results with short page excerpts,
fetch returns the current page as clean markdown.

## Requirements

- maki 0.5.6 or newer
- Optional: a Keenable API key from [app.keenable.ai](https://app.keenable.ai)

## Install

Add the package in `~/.config/maki/init.lua`:

```lua
maki.pack.add({
  { src = "https://github.com/bzzimmy/maki-keenable", version = "main" },
})
```

Then run `/reload` in maki.

## Setup

None is required. Without a key the tools call Keenable's keyless endpoints,
which allow 1,000 requests per hour per IP address.

To lift the hourly limit, set the `KEENABLE_API_KEY` environment variable. A
key includes 100,000 free requests a month.

## Tools

| Tool | Keenable API | Use it for |
| --- | --- | --- |
| `web_search` | Search (`/v1/search`) | Source discovery: titles, URLs, dates, and excerpts. Returns 10 results with excerpts of up to 500 characters. |
| `web_fetch` | Fetch (`/v1/fetch`) | Reading a known URL as markdown. Always fetches the live page, up to 20,000 characters. A `prompt` returns only the part you ask for. |

Disable maki's built-in web tools in your config so the agent picks these:

```lua
maki.setup({
  plugins = {
    websearch = { enabled = false },
    webfetch = { enabled = false },
  },
})
```

## Permissions

The package requests exactly what it calls: `net` for API requests and `env`
to read `KEENABLE_API_KEY`.

## Development

Clone the repository and run the checks from its root. The test command requires
`cargo-nextest`.

```sh
git clone https://github.com/bzzimmy/maki-keenable.git
cd maki-keenable
just check && just lint && just test
```
