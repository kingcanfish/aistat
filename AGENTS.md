# AGENTS.md

Guidance for coding agents (OpenAI Codex, Claude Code, and anything else that
reads `AGENTS.md`) working in this repository. `CLAUDE.md` is a symlink to this
file, so this is the single file to edit.

## What this is

AIStat is a Tauri 2 menu bar / status bar app that polls AI service status pages
(status.claude.com, status.openai.com, status.deepseek.com by default) and shows
the aggregate worst status as a tray icon. README.md covers user-facing features,
install and the release secrets; this file covers what you need to change code.

## Commands

```sh
cargo test --workspace                          # 47 tests: 35 in aistat-core, 12 in src-tauri (tray geometry + icon raster)
cargo test -p aistat-core                       # core only — this is all CI runs
cargo test -p aistat --lib                      # tray tests only; they need no display
cargo test -p aistat-core aggregate_picks_most  # single test by substring
cargo run -p aistat-core --example smoke        # live fetch of the default sites, prints normalized status
AISTAT_LOG=debug cargo run -p aistat-core --example smoke

cargo tauri dev                                 # dev run (needs a display; tray-only app, no window appears until you click the tray icon)
cargo tauri build                               # release bundle
```

`cargo tauri` needs the Tauri CLI (`cargo install tauri-cli --version "^2" --locked`,
or `npm i -g @tauri-apps/cli`). There is **no frontend build step** — `ui/` is
served as-is (`frontendDist: "../ui"`), so a UI change only needs a window reload.

`AISTAT_LOG` controls logging in both the app and the smoke example
(default `warn,aistat_lib=info,aistat_core=info`). Note the target is `aistat_lib`,
not `aistat` — that's the `[lib] name` in `src-tauri/Cargo.toml`.

There is no `rustfmt.toml` and a few lines deliberately sit past rustfmt's
100-column default. Running `cargo fmt` across the tree reflows unrelated code;
check `cargo fmt --check` output before applying anything.

CI (`.github/workflows/release.yml`) only runs on `v*` tags. It runs
`cargo test -p aistat-core --locked` inside each of the five build jobs — the
`src-tauri` tests are *not* run there, so run `cargo test --workspace` yourself.
There is no lint/clippy job and no PR workflow, so a break is only caught at release.

## Architecture

Three layers, in dependency order:

- **`crates/core/`** — Tauri-agnostic. Model, config, HTTP providers, normalization,
  aggregation, snapshot diffing. Most unit-testable logic lives here (35 tests).
  Never reach for `tauri` from this crate.
- **`src-tauri/`** — the shell. `lib.rs` owns the refresh loop, IPC commands and
  notifications; `tray.rs` owns the tray icon (drawn procedurally, see below) and
  all panel geometry (and carries 12 tests of its own for the icon raster and
  panel placement); `state.rs` is the shared `AppState`.
- **`ui/`** — three static files. `app.js` talks to Rust via `window.__TAURI__`
  (`withGlobalTauri: true`), no bundler, no modules.

### The refresh cycle

`refresh_once` (`src-tauri/src/lib.rs`) is the single path that updates anything:
fetch all sites concurrently (`fetch_all`) alongside icon resolution → `detect_changes`
against the previous snapshot → store into `AppState` → `update_tray` → emit
`status-updated` to the webview → fire notifications for each change. It's called
by the setup hook, by `spawn_scheduler` on the configured interval (floored at 30s),
and by the `refresh_now` command. Anything that needs to affect the tray or the
panel should go through it rather than mutating state directly.

### Cross-cutting invariants

**The status vocabulary is duplicated in four places.** Adding or renaming a
`Status` variant means touching all of them:
1. `crates/core/src/model.rs` — the enum, `DEFAULT_PRIORITY`, `label()`, `color()`
2. `src-tauri/src/tray.rs` — `status_rgb` (the tray icon tint)
3. `ui/app.js` — `SEVERITY` and `LABELS` (the JS copy of the priority order)
4. `ui/style.css` — the `.dot--<status>` classes

Serde uses `snake_case`, so the JSON wire values (`partial_outage`, `full_outage`)
are what the JS sees.

**IPC commands are declared twice**: in `invoke_handler![...]` in `lib.rs` and at
each `invoke("name", ...)` call site in `ui/app.js`. Argument names are camelCase
on the JS side and snake_case in Rust — Tauri converts them.

**Aggregation is always "worst wins", never "trust the provider".** A StatusPage
page-level indicator is hand-maintained and lags, so `statuspage::to_status` takes
the worst of the indicator, every non-group component, and any in-progress
scheduled maintenance. Similarly, an *open* incident with `impact: none` maps to
`Unknown`, not `Operational` — see the doc comments in `normalize.rs`, which quote
the upstream API contracts and are the reference for any mapping change.

### Adding a status provider

1. Add a variant to `AdapterKind` (`crates/core/src/config.rs`).
2. Add `providers/<name>.rs` exposing `pub const <X>_PATH` and
   `pub async fn fetch(&Client, &SiteConfig) -> Result<SiteStatus, ProviderError>`.
3. Wire it into the `match` in `providers::fetch_site` **and** into the concurrent
   probe in `providers::detect_adapter` — the settings UI has no adapter picker,
   it detects the adapter from the URL, so a provider missing from `detect_adapter`
   can never be added by a user.
4. Add its vocabulary mapping to `normalize.rs` with the documented value set in a test.
5. Mention it in the "unsupported" error string in the `detect_adapter` command
   (`src-tauri/src/lib.rs`), which names the supported paths.

### Networking

One `reqwest::Client` for the whole process, held in `AppState.http` — rebuilding
it per refresh throws away connection pooling and TLS session reuse (~600ms → ~300ms
for a warm three-site refresh).

The TLS backend is `rustls-graviola`, chosen for a non-obvious reason documented at
`providers::install_tls_backend`: `status.deepseek.com` sits behind a middlebox that
resets connections whose ClientHello fits in one TCP segment, and offering the ~1.2KB
X25519MLKEM768 key share first pushes it past that boundary. A unit test asserts the
post-quantum group is offered *first* with classical groups behind it, because a
backend upgrade that reorders them would only surface as DeepSeek silently going
Unknown in the menu bar. (README's closing note about a `curl` fallback in
`fetch_text` is stale — that path was replaced by this TLS fix.)

Per-site failures never fail a batch: `fetch_all` turns them into
`SiteStatus::from_error` with `Status::Unknown` and an `error` string that the panel
row shows verbatim, which is why `ProviderError::Http` renders its whole source chain.

### Panel behavior (tray.rs + app.js)

The window is a frameless, transparent, always-on-top popover that is hidden by
default and anchored under the tray icon from the rect in the last `TrayIconEvent`.
Three pieces of state make it feel native, and all three are easy to break:

- **Dismiss on blur** — `on_window_event` hides the window on `Focused(false)`.
- **`pinned`** — set from JS via `set_panel_pinned` once the settings form is
  *dirty*, so a stray click can't discard typed input. Merely opening settings
  does not pin.
- **`hidden_at` + `DISMISS_DEBOUNCE_MS`** — a tray click while the panel is open
  first blurs (hides) it, so a click arriving within 250ms of a hide is swallowed
  instead of reopening.

Height is content-driven in the other direction from usual: JS measures the visible
view under a `ResizeObserver` and calls `resize_panel`, which clamps between
`PANEL_MIN_HEIGHT`/`PANEL_MAX_HEIGHT` and repositions against the monitor.

The tray icon is rasterized in Rust, not loaded from a file — `robot_mask` is a
signed-distance-ish silhouette sampled with 4×4 supersampling into a 36px RGBA
image tinted by the aggregate status.

Icons for site rows are scraped from each page's `<link rel=icon>` and cached in
`AppState.icons` as `HashMap<url, Option<String>>`; `Some(None)` means "checked,
has none" so the HTML isn't refetched every poll.

## Releasing

`[workspace.package] version` in the root `Cargo.toml` is the single source of truth.
`tauri.conf.json` intentionally has **no** `version` field so Tauri falls back to it,
and the release workflow refuses to build a tag that disagrees.

```sh
scripts/release.sh 0.2.0            # validates, bumps Cargo.toml, refreshes Cargo.lock, commits, tags
git push origin main --follow-tags  # starts the build
```

Never hand-edit the version: the script also runs `cargo update --workspace` and
asserts `cargo metadata --locked` still passes, because every CI job builds
`--locked` and a stale lock fails five platforms in.

## Conventions

Commit subjects are imperative and sentence-case, describing the user-visible
effect ("Make the release script actually refresh Cargo.lock", "Hide the panel
scrollbars") — no Conventional Commits prefixes.

Comments in this codebase explain *why*, especially for anything that looks
arbitrary (the TLS backend, the debounce window, the `impact: none` mapping, the
`system-proxy` feature flag). Several are load-bearing documentation of upstream
behavior. Match that density rather than the usual sparse style, and don't delete
one without understanding what it's guarding.
