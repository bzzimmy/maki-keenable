maki-keenable is a maki lua plugin that gives the agent Keenable web search and page fetch. It loads through the maki pack system, not as a builtin.

## Code guidelines

- Lua in `plugin/`. No trivial comments, minimal bloat, no unnecessary state.
- Keep the `MAX_*` constants at the top of the file.
- Fallible runtime operations return the `(value, err)` pair and never throw. Tool handlers fail with `{ llm_output = msg, is_error = true }`; a plain string is always success.
- Every tool that declares `permission_scopes` must also declare `permission`, and the capability must be granted in `plugin.toml`. maki refuses the load otherwise.
- `plugin.toml` grants exactly what the code calls. Keep it aligned by hand.
- Keep the tool schemas and descriptions short: they are sent on every request. Render less rather than raising limits.

## Keenable API

- Base URL `https://api.keenable.ai`. Search is `POST /v1/search` with a JSON body. Fetch is `GET /v1/fetch` with query parameters, always sent with `live=true`.
- With a key: send `X-API-Key: keen_...`, read from `KEENABLE_API_KEY`. Without one: use `/v1/search/public` and `/v1/fetch/public`, which require an `X-Keenable-Title` header. A blank env var counts as no key.
- Errors are JSON with top-level `error`, `message`, `code`, `fix`, and `retryable`. Branch on `code`, never on `message`.
- Sources of truth: `https://api.keenable.ai/openapi.json` and `https://docs.keenable.ai/api-reference`.

## Testing

Cheapest first:

```
just check
just lint
just test
```

Tests live in `tests/` and load the plugin through the real `maki-lua` host with `PluginHost::load_package`, passing the repo root (it derives `plugin/` itself; passing `plugin/` fails with `PackageEmpty`).

Tests never call the live Keenable API. They load the plugin source with `PluginHost::load_source` after stubbing `maki.net.request` and `maki.uv.os_getenv`, and the stub echoes the request back so the output shows what was sent.

Assert Lua-visible effects (tool output, mailbox messages), not just files. `smol::unblock` side effects land even when a callback aborts, so file-only checks can pass while the Lua-level API is broken.

Dev-dependencies pin a revision of maki. `Cargo.lock` pins the transitive registry deps too, because a bare rev pin lets a newer transitive crate drift in and break the host build. When the host changes something the plugin uses, move the rev in `Cargo.toml` and regenerate `Cargo.lock` together.

## Layout

- `plugin/maki_keenable.lua`: both tools and the shared request code.
- `plugin.toml`: `min_maki_version` and the `[permissions]` request.
- `tests/`: host harness and integration tests.
- `justfile`: check, lint, test, fmt-lua.
- `stylua.toml`: must carry `syntax = "Luau"`. Run `stylua plugin/` before committing (v2.6.0+).

## Docs

The README is the canonical home for install and usage. Follow the maki docs voice: plain words, no em-dashes, no contractions, state facts once.
