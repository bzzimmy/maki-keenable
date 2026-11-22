use std::path::Path;
use std::sync::Arc;

use maki_agent::ToolOutput;
use maki_agent::tools::ToolRegistry;
use maki_lua::{PluginHost, PluginPermissions};
use serde_json::json;

const PLUGIN_NAME: &str = "maki-keenable";
const PLUGIN_SOURCE: &str = include_str!("../plugin/maki_keenable.lua");

fn plugin_host() -> (Arc<ToolRegistry>, PluginHost) {
    let reg = Arc::new(ToolRegistry::new());
    let host = PluginHost::new(Arc::clone(&reg)).unwrap();
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    host.load_package(
        PLUGIN_NAME,
        root,
        PluginPermissions::trusted(),
        Default::default(),
    )
    .unwrap();
    (reg, host)
}

/// Loads the plugin with `maki.net.request` and `KEENABLE_API_KEY` stubbed.
/// {respond} is a Lua function body that sees `url` and `opts` and returns
/// the response table.
fn stubbed_host(key: Option<&str>, respond: &str) -> (Arc<ToolRegistry>, PluginHost) {
    let reg = Arc::new(ToolRegistry::new());
    let host = PluginHost::new(Arc::clone(&reg)).unwrap();
    let key = key.map_or("nil".to_owned(), |k| format!("{k:?}"));
    host.load_source(
        PLUGIN_NAME,
        &format!(
            "maki.uv.os_getenv = function() return {key} end\n\
             maki.net.request = function(url, opts) {respond} end\n\
             {PLUGIN_SOURCE}"
        ),
    )
    .unwrap();
    (reg, host)
}

fn exec_tool(reg: &ToolRegistry, name: &str, input: serde_json::Value) -> Result<String, String> {
    let entry = reg
        .get(name)
        .unwrap_or_else(|| panic!("tool {name} not registered"));
    let inv = entry.tool.parse(&input).map_err(|err| err.to_string())?;
    let ctx = maki_agent::tools::test_support::stub_ctx(&maki_agent::AgentMode::Build);
    smol::block_on(async { inv.execute(&ctx).await })
        .output
        .map_or_else(Err, |out| match out {
            ToolOutput::Plain(s) | ToolOutput::Markdown(s) => Ok(s.text),
            other => panic!("unexpected output: {other:?}"),
        })
}

/// Echoes the request URL, key header, and body back as one search result.
const ECHO_SEARCH: &str = r#"local echo = maki.json.encode({ title = "Echo", url = "https://example.com",
    snippet = url .. " key=" .. tostring(opts.headers["X-API-Key"]) .. " " .. opts.body })
return { status = 200, body = '{"results":[' .. echo .. ',{"title":"Dup","url":"https://example.com","snippet":"dropped"}'
    .. ',{"title":null,"url":"https://example.org","published_at":"2026-11-13T05:44:15Z","snippet":null}]}' }"#;

#[test]
fn tools_register() {
    let (reg, _host) = plugin_host();
    for tool in ["web_search", "web_fetch"] {
        assert!(reg.has(tool), "tool {tool} should register");
    }
}

#[test]
fn search_without_a_key_uses_the_public_endpoint() {
    let (reg, _host) = stubbed_host(None, ECHO_SEARCH);
    let out = exec_tool(&reg, "web_search", json!({ "query": "tokio select" })).unwrap();
    assert!(
        out.starts_with(
            "[1] Echo (https://example.com)\nhttps://api.keenable.ai/v1/search/public key=nil "
        ),
        "got: {out}"
    );
    for field in [
        r#""max_results":10"#,
        r#""snippet_max_length":500"#,
        r#""disable_cards":true"#,
    ] {
        assert!(out.contains(field), "missing {field} in: {out}");
    }
    assert!(!out.contains("Dup"), "duplicate URLs are dropped: {out}");
    assert!(
        out.ends_with("\n\n[2] https://example.org (https://example.org) - published 2026-11-13"),
        "got: {out}"
    );
}

#[test]
fn search_with_a_key_uses_the_keyed_endpoint() {
    let (reg, _host) = stubbed_host(Some(" keen_test \n"), ECHO_SEARCH);
    let out = exec_tool(&reg, "web_search", json!({ "query": "tokio select" })).unwrap();
    assert!(
        out.contains("https://api.keenable.ai/v1/search key=keen_test "),
        "got: {out}"
    );
}

#[test]
fn fetch_is_live_and_renders_the_page() {
    let (reg, _host) = stubbed_host(
        None,
        r###"return { status = 200, body = '{"url":"https://example.com/final","title":"Example","author":null,'
            .. '"published_at":null,"truncated":true,"total_chars":99999,"content":'
            .. maki.json.encode("## [](https://x#a)Intro [![v](https://img/v.svg)](https://pypi) " .. url) .. '}' }"###,
    );
    let out = exec_tool(
        &reg,
        "web_fetch",
        json!({ "url": "https://example.com/a b", "prompt": "list & sum" }),
    )
    .unwrap();
    assert_eq!(
        out,
        "# Example\nhttps://example.com/final\n\n\
         ## Intro  https://api.keenable.ai/v1/fetch/public?url=https%3A%2F%2Fexample.com%2Fa%20b&live=true&max_chars=20000&prompt=list%20%26%20sum\n\n\
         [cut at 20000 of 99999 chars; call again with prompt to extract a part]"
    );
}

#[test]
fn errors_carry_the_keenable_code_and_retry_hint() {
    let (reg, _host) = stubbed_host(
        None,
        r#"return { status = 429, body = '{"error":"Rate limit exceeded","message":"Too many requests","code":"public_rate_limit_hourly","retryable":true}' }"#,
    );
    let err = exec_tool(&reg, "web_fetch", json!({ "url": "https://example.com" })).unwrap_err();
    assert_eq!(
        err,
        "error: Keenable HTTP 429: Too many requests (public_rate_limit_hourly). Retryable. \
         Set KEENABLE_API_KEY to raise the limit."
    );
}

#[test]
fn input_is_validated_before_any_network() {
    let (reg, _host) = stubbed_host(None, r#"error("network must not be reached")"#);
    let err = exec_tool(&reg, "web_search", json!({ "query": "  " })).unwrap_err();
    assert!(err.contains("query is required"), "got: {err}");
    let err = exec_tool(&reg, "web_fetch", json!({ "url": "ftp://example.com" })).unwrap_err();
    assert!(err.contains("http(s) URL"), "got: {err}");
}
