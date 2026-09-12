# AIStat

Cross-platform status bar/menu bar app that monitors AI service status pages in
the background, shows an aggregate status in the tray, and notifies you on
status changes.

Two builds of the same app. **macOS** is native AppKit + SwiftUI (`macos/`);
**Windows and Linux** are **Tauri** (Rust + a web frontend). Both ship the same
three adapters, read the same config file, and follow the same rules for what a
status means:

| Site | Underlying service | Adapter |
|------|--------------------|---------|
| status.claude.com | Atlassian StatusPage | `statuspage` |
| status.openai.com | incident.io (StatusPage-compatible API) | `statuspage` |
| status.deepseek.com | FlashDuty / Flashcat | `flashduty` |

## Install

**macOS (Homebrew)**

```sh
brew tap kingcanfish/tap
brew install --cask aistat
```

**Everything else** — grab an installer from the
[latest release](https://github.com/kingcanfish/aistat/releases/latest):

| Platform | Architectures | Artifact |
|---|---|---|
| macOS 14+ | Intel + Apple Silicon (universal) | `.dmg` (native app) |
| Windows | x86_64, arm64 | `.exe` (NSIS); x86_64 also gets `.msi` |
| Linux | x86_64, aarch64 | `.deb`, `.rpm`; x86_64 also gets `.AppImage` |

Builds are not code-signed. On macOS clear the quarantine flag once with
`xattr -dr com.apple.quarantine "/Applications/AIStat.app"`; on Windows choose
*More info* → *Run anyway* at the SmartScreen prompt.

## Features

- Tray icon reflects the aggregate (worst) status across all sites.
- Click it for the panel — anchored under the icon, sized to its content up to a
  maximum, dismissing itself when it loses focus.
- The panel is a translucent vibrancy surface and follows the system light/dark
  mode and accent color.
- Menu bar only, no Dock icon (`LSUIElement` on macOS).
- The menu bar icon is a robot tinted with the aggregate status color; each site
  row shows the status page's own logo, scraped from its `<link rel=icon>`.
- Configurable refresh interval (default 300s) and desktop notifications on
  status change.
- Add/remove sites from settings. The adapter is **detected automatically**
  from the URL — pages that expose neither supported API are reported instead
  of being saved.

macOS additionally has **start at login**, and distinguishes the six states by
SF Symbol shape as well as colour, so the reading survives for a colour-blind
user. Its settings live in a window of their own rather than inside the panel.
Windows and Linux keep the right-click tray menu (Refresh / Settings / Quit);
the native build puts those in the panel's own footer instead.

## Status model

| Status | Meaning | Color |
|--------|---------|-------|
| `operational` | Operational | 🟢 green |
| `degraded` | Degraded performance | 🟡 yellow |
| `partial_outage` | Partial outage | 🟠 orange |
| `full_outage` | Full outage | 🔴 red |
| `maintenance` | Maintenance | 🔵 blue |
| `unknown` | Fetch failed | ⚪ gray |

## Project layout

```
crates/core/     Tauri-agnostic core: model, config, providers, snapshot diffing
src-tauri/       Tauri app: tray, scheduler, notifications, IPC commands
ui/              Static web frontend (no build step)
macos/           The native macOS app (SwiftPM). See macos/README.md.
```

The domain logic exists twice — once in `crates/core`, once in
`macos/Sources/AIStatCore` — because the two shells share no code. A change to a
provider mapping is a bug until it lands in both; AGENTS.md lists the pairs.

## Prerequisites

- Rust (stable), for the Windows/Linux build
- Xcode 15 or newer, for the macOS build
- Platform webview deps:
  - Linux: `webkit2gtk-4.1`, `gtk3`, `libayatana-appindicator`, `librsvg`
    (Arch: `sudo pacman -S webkit2gtk-4.1 libayatana-appindicator`)
  - macOS/Windows: handled automatically

## Build & run

```sh
# run the core unit tests
cargo test -p aistat-core

# live smoke test against the real status pages
cargo run -p aistat-core --example smoke

# dev run (needs a display)
cargo tauri dev

# release build
cargo tauri build
```

`cargo tauri` requires the Tauri CLI: `npm i -g @tauri-apps/cli` (or use
`bunx @tauri-apps/cli`).

The native macOS app builds from `macos/`:

```sh
cd macos
swift test                            # 56 tests, no display needed
swift run aistat-smoke                # live fetch of the default sites
UNIVERSAL=1 DMG=1 Scripts/bundle.sh   # what CI ships
open .build/bundle/AIStat.app
```

`cargo tauri build` on a Mac still produces a macOS Tauri bundle — that is how
you develop `ui/` without a Windows or Linux machine — but it is not what gets
released.

## Releasing

`[workspace.package] version` in `Cargo.toml` is the single source of truth.
`tauri.conf.json` deliberately has **no** `version` field, so Tauri falls back
to Cargo.toml, and `.github/workflows/release.yml` refuses to build a tag that
disagrees with it.

```sh
scripts/release.sh 0.2.0                 # bump, commit, tag
git push origin main --follow-tags       # start the build
```

Pushing a `v*` tag runs the release workflow, which:

1. checks the tag against `Cargo.toml` and opens a draft release;
2. builds four Tauri targets and the native macOS app in parallel, and uploads
   their bundles;
3. publishes the release;
4. renders `Casks/aistat.rb` and pushes it to `kingcanfish/homebrew-tap`.

**Required secret:** `HOMEBREW_TAP_TOKEN` — a PAT with `contents:write` on the
tap repository. Without it every step still runs but the tap update fails.

**Optional secrets** for signed, notarized macOS builds. The workflow already
passes them through, so adding them is all that's needed:
`APPLE_CERTIFICATE`, `APPLE_CERTIFICATE_PASSWORD`, `APPLE_SIGNING_IDENTITY`,
`APPLE_ID`, `APPLE_PASSWORD`, `APPLE_TEAM_ID`.

## Configuration

On first launch a default `config.json` is written to the platform config dir
(e.g. `~/.config/com.aistat.app/config.json` on Linux). Settings can also be
edited from the panel's gear icon.

```json
{
  "refresh_interval_seconds": 300,
  "notifications_enabled": true,
  "launch_at_login": false,
  "status_priority": ["full_outage","partial_outage","maintenance","degraded","operational","unknown"],
  "sites": [
    { "id": "claude",   "name": "Claude",   "url": "https://status.claude.com",  "adapter": "statuspage" },
    { "id": "openai",   "name": "OpenAI",   "url": "https://status.openai.com",  "adapter": "statuspage" },
    { "id": "deepseek", "name": "DeepSeek", "url": "https://status.deepseek.com","adapter": "flashduty" }
  ]
}
```

## Notes

- A site's overall status is the **worst** of its page-level indicator, all of
  its component statuses, and any in-progress maintenance. StatusPage's
  indicator is set by hand and lags: status.claude.com has reported "minor"
  while four components were in partial outage.
- An open incident whose StatusPage `impact` is `none` is *unclassified*, not
  resolved, so it renders gray rather than operational green.

- The FlashDuty widget ([schema](https://docs.flashduty.com/zh/on-call/statuspage/widgets))
  has no standalone component list — it only names the components an active
  incident or maintenance affects, so those are the only ones shown.
- `launch_at_login` is currently stored but not yet wired to OS autostart.
- `status.deepseek.com` sits behind a middlebox that closes the connection
  during the TLS handshake for **both** Rust TLS stacks (rustls and the macOS
  Security.framework backend), while accepting OpenSSL's. `providers::fetch_text`
  therefore falls back to the system `curl` when a request dies before any
  response arrives; `curl` ships on macOS, Linux and Windows 10+.
