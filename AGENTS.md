# AGENTS.md

Guidance for coding agents (OpenAI Codex, Claude Code, and anything else that
reads `AGENTS.md`) working in this repository. `CLAUDE.md` is a symlink to this
file, so this is the single file to edit.

## What this is

AIStat is a menu bar / status bar app that polls AI service status pages
(status.claude.com, status.openai.com, status.deepseek.com by default) and shows
the aggregate worst status as a tray icon. README.md covers user-facing features,
install and the release secrets; this file covers what you need to change code.

**There are two shells over the same product.** `src-tauri/` + `ui/` is the
Tauri 2 build, and it now ships Windows and Linux only. `macos/` is a native
AppKit + SwiftUI app, and it is what macOS ships — same bundle identifier, same
config file, so an existing install upgrades in place. They share no code: the
domain logic exists twice, once in Rust and once in Swift, which is the single
most important thing to know before changing anything (see the invariant
below).

## Commands

```sh
cargo test --workspace                          # 53 tests: 35 in aistat-core, 18 in src-tauri (tray geometry + icon raster)
cargo test -p aistat-core                       # core only — this is all CI runs
cargo test -p aistat --lib                      # tray tests only; they need no display
cargo test -p aistat-core aggregate_picks_most  # single test by substring
cargo run -p aistat-core --example smoke        # live fetch of the default sites, prints normalized status
AISTAT_LOG=debug cargo run -p aistat-core --example smoke

cargo tauri dev                                 # dev run (needs a display; tray-only app, no window appears until you click the tray icon)
cargo tauri build                               # release bundle
```

macOS, from `macos/`:

```sh
swift test                                      # 56 tests, no display needed
swift test --filter StatusPageTests             # one suite; --filter matches type/function names, not @Suite titles
swift run aistat-smoke                          # live fetch of the default sites
swift run aistat-preview docs/preview           # render the UI off-screen to PNGs
UNIVERSAL=1 DMG=1 Scripts/bundle.sh             # what CI ships
open .build/bundle/AIStat.app
log stream --predicate 'subsystem == "com.aistat.app"' --level debug
```

`swift run AIStat` starts, but three behaviours need the bundle `Scripts/bundle.sh`
builds and do nothing without it: `LSUIElement`, `UNUserNotificationCenter`
(refuses to post with no registered bundle identifier) and `SMAppService`
(nothing to register as a login item).

`cargo tauri build` on a Mac still produces a macOS Tauri bundle. That is left
working on purpose — it is how you develop `ui/` without a Windows or Linux
machine — but it is not what gets released.

`cargo tauri` needs the Tauri CLI (`cargo install tauri-cli --version "^2" --locked`,
or `npm i -g @tauri-apps/cli`). There is **no frontend build step** — `ui/` is
served as-is (`frontendDist: "../ui"`), so a UI change only needs a window reload.

`AISTAT_LOG` controls logging in both the app and the smoke example
(default `warn,aistat_lib=info,aistat_core=info`). Note the target is `aistat_lib`,
not `aistat` — that's the `[lib] name` in `src-tauri/Cargo.toml`.

There is no `rustfmt.toml` and a few lines deliberately sit past rustfmt's
100-column default. Running `cargo fmt` across the tree reflows unrelated code;
check `cargo fmt --check` output before applying anything.

There are two workflows. `.github/workflows/ci.yml` runs on every push and pull
request (tags excluded) and is what you should expect to catch a break: it
builds and tests the Swift package, runs `cargo test -p aistat-core --locked`,
and runs `Scripts/bundle.sh` to check the app still assembles universal and
versioned. `.github/workflows/release.yml` runs only on `v*` tags and repeats
the same commands inside the jobs that produce artifacts.

**Both macOS jobs run on `macos-26`, and the runner label is load-bearing.**
They were on `macos-15` for exactly one release and it cost two things. Its
Xcode is older, and the two toolchains disagree about how much actor isolation
SwiftUI infers for a `View` — v0.3.0 failed twice on code that compiled clean
locally, once because a static touching `NSApp` had no `@MainActor` and once
because a test suite calling `MenuBarGlyph.weight(for:status:)` had none. Worse,
it shipped: macOS picks an app's design language from the SDK it was *linked
against*, so a build against the 15.5 SDK renders in the pre-Tahoe style on
macOS 26 — no Liquid Glass — while every local build had it. Nothing in the
source says which SDK was used and nothing failed; the released app just looked
older than the development one.

So the `bundle` job asserts the binary was linked against the runner's own SDK.
Annotate isolation rather than relying on inference, and do not read a green
local run as a green CI run.

`src-tauri`'s own tests run in neither workflow, so run `cargo test --workspace`
yourself. There is no lint or clippy job, and no `cargo fmt` check — see above
for why.

## Architecture

Three layers, in dependency order:

- **`crates/core/`** — Tauri-agnostic. Model, config, HTTP providers, normalization,
  aggregation, snapshot diffing. Most unit-testable logic lives here (35 tests).
  Never reach for `tauri` from this crate.
- **`src-tauri/`** — the shell. `lib.rs` owns the refresh loop, IPC commands and
  notifications; `tray.rs` owns the tray icon (drawn procedurally, see below) and
  all panel geometry (and carries 18 tests of its own for the icon raster and
  panel placement); `state.rs` is the shared `AppState`.
- **`ui/`** — three static files. `app.js` talks to Rust via `window.__TAURI__`
  (`withGlobalTauri: true`), no bundler, no modules.
- **`macos/`** — the native app, a SwiftPM package. `Sources/AIStatCore/` is the
  Swift counterpart of `crates/core` and is AppKit-free for the same reason;
  `Sources/AIStatUI/` is the shell (status item, popover, settings window,
  model); `Sources/AIStatApp/` is one line, because a SwiftPM executable target
  cannot be imported by tests. `macos/README.md` explains what the native
  platform let it delete from the Tauri design, and why `MenuBarExtra` is not
  used.

### The refresh cycle

`refresh_once` (`src-tauri/src/lib.rs`) is the single path that updates anything:
fetch all sites concurrently (`fetch_all`) alongside icon resolution → `detect_changes`
against the previous snapshot → store into `AppState` → `update_tray` → emit
`status-updated` to the webview → fire notifications for each change. It's called
by the setup hook, by `spawn_scheduler` on the configured interval (floored at 30s),
and by the `refresh_now` command. Anything that needs to affect the tray or the
panel should go through it rather than mutating state directly.

### Cross-cutting invariants

**The domain logic exists twice, and a change to one copy is a bug until it
lands in both.** These pairs have no shared source and nothing will fail if they
drift — the two builds will simply disagree about whether a service is down:

| Rust | Swift |
|---|---|
| `crates/core/src/normalize.rs` | `macos/Sources/AIStatCore/Normalize.swift` |
| `crates/core/src/aggregate.rs` | `aggregate()` in `macos/Sources/AIStatCore/Status.swift` |
| `crates/core/src/providers/statuspage.rs` | `macos/Sources/AIStatCore/Providers/StatusPageProvider.swift` |
| `crates/core/src/providers/flashduty.rs` | `macos/Sources/AIStatCore/Providers/FlashDutyProvider.swift` |
| `crates/core/src/providers/icon.rs` | `macos/Sources/AIStatCore/Providers/IconResolver.swift` |
| `crates/core/src/snapshot.rs` | `macos/Sources/AIStatCore/Snapshot.swift` |
| `crates/core/src/config.rs` | `macos/Sources/AIStatCore/Config.swift` |

Both sides carry the same tests for the same reason, so porting a fix means
porting its test. The config pair is stricter than the rest: the JSON wire names
must stay identical, because both builds read
`~/Library/Application Support/com.aistat.app/config.json` and a macOS user
moving between them must keep their settings. `readsAConfigWrittenByTheRustBuild`
in `macos/Tests/AIStatCoreTests/ConfigTests.swift` pins that.

What is deliberately *not* duplicated is everything under `src-tauri/` — the
tray raster, the panel geometry, the appearance probe, the notification identity
dance. The native platform supplies all of it; `macos/README.md` has the table.


**The status vocabulary is duplicated in four places.** Adding or renaming a
`Status` variant means touching all of them:
1. `crates/core/src/model.rs` — the enum, `DEFAULT_PRIORITY`, `label()`, `color()`
2. `src-tauri/src/tray.rs` — `status_rgb` (the tray icon tint; **two** arms per
   status, one per menu bar appearance) and `weight_for` (which weight the
   escalating icon style gives it)
3. `ui/app.js` — `SEVERITY` and `LABELS` (the JS copy of the priority order)
4. `ui/style.css` — the `.dot--<status>` classes

Serde uses `snake_case`, so the JSON wire values (`partial_outage`, `full_outage`)
are what the JS sees.

**A new `Config` field is declared four times**: the struct and its `Default`
(`crates/core/src/config.rs`), the row in `ui/index.html`, and both halves of
the round trip in `ui/app.js` (`openSettings` fills the control, `saveSettings`
reads it back). Miss the `saveSettings` half and the setting silently reverts
on every save. Every field carries `#[serde(default)]` so an older config file
still loads.

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

### Notifications

`claim_notification_identity` runs in the setup hook and must stay there.
`notify-rust`'s macOS backend needs a Launch Services–registered bundle
identifier to post at all, and if nothing has named one by the first `show()`
it runs the AppleScript `get id of application "use_default"` — which opens the
system "Choose Application" picker in the user's face, at the moment a site
changed status. Claiming the identifier up front spends the crate's one-shot
`Once` so that lookup never happens; a loose dev binary has no identifier and
falls back to `com.apple.Finder`, which is fine because spending the `Once` is
the part that matters.

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

The tray icon is rasterized in Rust, not loaded from a file. The geometry is
written in **icon points** (an 18pt box, the height macOS draws a status item)
and rasterized at 2px per point into 36px RGBA with 4×4 supersampling.
`RoundRect::distance` is a real signed distance field rather than a
containment test, because two of the three weights *stroke* the head and a
stroke is just the band where |distance| is within half the pen.

`Config::icon_style` picks one of three renderings (`weight_for`):

- **Calm** — monochrome glyph in the menu bar's label colour, status in a
  corner lamp punched out of the outline.
- **Tinted** — the glyph itself in the status colour, on a 1.6pt pen (coloured
  ink at mid luminance reads thinner than black on white).
- **Filled** — the calm shapes with the head inked in, eyes knocked out.

`IconStyle::Escalating` (the default) maps severity onto those three; `Lamp`
and `Tinted` pin every status to one. Two invariants have tests and are easy
to break: the lamp sits **inside** the head's outer edge and the filled weight
reuses the calm shapes, so the mark's bounding box does not move when the
status changes; and nothing reaches the bitmap edge, since there is no longer
a keyline to hide clipping.

### The menu bar's appearance is not the system appearance

`src-tauri/src/appearance.rs` exists because of one macOS fact that is easy to
get wrong and was shipped wrong here once: the menu bar is translucent over the
desktop picture, and AppKit picks its *content* appearance from what is behind
it. A Mac in **Light** appearance with a dark wallpaper gets a **dark** menu
bar, with every template icon in it drawn white. Verified on this machine:
`defaults read -g AppleInterfaceStyle` is unset (Light) while the bar renders
its icons white.

So `AppleInterfaceStyle`, `NSApp.effectiveAppearance` and Tauri's
`Window::theme()` are all the wrong question — they say Light and you paint a
black glyph onto a black bar. The supported answer is the status item's own
`button.effectiveAppearance`. Tauri does not expose its status item, so
`appearance.rs` keeps a **zero-length `NSStatusItem` of its own** (public API,
no visible footprint, same value the real item sees), observes that button's
appearance with **KVO**, and caches the answer in an atomic — AppKit only
answers on the main thread, while the refresh loop draws from a worker.

Three things follow, and all three have comments guarding them:

- **Registration must happen outside the `RefCell` borrow.** `Initial` makes
  `addObserver:` deliver the first callback *synchronously*, and that callback
  reads the probe straight back. Registering while still inside
  `borrow_mut()` panics with "RefCell already borrowed" inside an `extern "C"`
  frame that cannot unwind — which aborts the app on launch (SIGABRT). So
  `ensure_observed` creates and stores the probe under a short mutable borrow,
  drops it, *then* registers. `read` takes a shared borrow for the same reason.
- **The probe cannot be read at setup.** Its button reports the *app*
  appearance until AppKit installs it in the bar, which has not happened inside
  the setup hook or a run loop turn later — measured. KVO is what makes this
  work: that installation is itself a change, delivered about a second in, well
  before the first network refresh.
- **Nothing else would notify you.** Changing the desktop picture flips the bar
  with no theme change and no user action, so KVO is the only mechanism that
  sees it. `update_tray` still calls `resync_appearance` as belt and braces in
  case the registration never took; it costs one string read per refresh and
  redraws only when the answer moved.

This was written as the honest answer to "would a Swift rewrite avoid this?" —
no — and `macos/` has since confirmed it. The native app owns its status item,
so the *probe* is gone, but it observes the same key path on it for the same
reason, and it needed the same two guards: coalesce the callback off the KVO
call-out, because assigning `button.image` makes AppKit report a transient
`DarkAqua` that reads exactly like the user switching appearance, and match on
the appearance *name* rather than `bestMatch`.

Apple's own advice is to sidestep all of this with a template image, which the
system tints for free — that is what `IconStyle` cannot use, because a template
image keeps nothing but the alpha channel and the status colour has to survive.
A palette pinned to one luminance so it needs no appearance at all was tried and
rejected: it is muddy on a dark bar, and costs more in colour than the observer
costs in code.

Icons for site rows are scraped from each page's `<link rel=icon>` and cached in
`AppState.icons` as `HashMap<url, Option<String>>`; `Some(None)` means "checked,
has none" so the HTML isn't refetched every poll.

## Releasing

`[workspace.package] version` in the root `Cargo.toml` is the single source of truth.
`tauri.conf.json` intentionally has **no** `version` field so Tauri falls back to it,
and the release workflow refuses to build a tag that disagrees.

The Swift side holds no copy of the number either: `macos/Scripts/bundle.sh`
reads it out of `../Cargo.toml` and stamps `CFBundleShortVersionString`, and
`AIStatCore.version` reads that back at runtime. So `scripts/release.sh` needs
no changes to cover macOS.

The release workflow has two build paths. The `build` matrix is Tauri and covers
Windows ×2 and Linux ×2; the `macos` job runs `swift test` and
`macos/Scripts/bundle.sh`, and uploads the dmg. The `homebrew` job is unchanged
by the split — it asks the release which `.dmg` is attached and renders the cask
from that, so it does not care which toolchain produced it.

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
