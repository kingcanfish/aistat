# AI Status

Cross-platform status bar/menu bar app that monitors AI service status pages in
the background, shows an aggregate status in the tray, and notifies you on
status changes.

Built with **Tauri (Rust + web frontend)**. Ships with three adapters:

| Site | Underlying service | Adapter |
|------|--------------------|---------|
| status.claude.com | Atlassian StatusPage | `statuspage` |
| status.openai.com | incident.io (StatusPage-compatible API) | `statuspage` |
| status.deepseek.com | FlashDuty / Flashcat | `flashduty` |

## Features

- Tray icon reflects the aggregate (worst) status across all sites.
- Click the tray icon (macOS/Windows) or the "Show/Hide Panel" menu item to open
  the panel with per-site components and latest incident descriptions.
- Configurable refresh interval (default 300s) and desktop notifications on
  status change.
- Add/remove sites and switch adapters from the settings panel.
- Add new providers by implementing `StatusProvider` in `crates/core`.

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
```

## Prerequisites

- Rust (stable)
- Platform webview deps:
  - Linux: `webkit2gtk-4.1`, `gtk3`, `libayatana-appindicator`, `librsvg`
    (Arch: `sudo pacman -S webkit2gtk-4.1 libayatana-appindicator`)
  - macOS/Windows: handled automatically

## Build & run

```sh
# run the core unit tests
cargo test -p aiisdown-core

# live smoke test against the real status pages
cargo run -p aiisdown-core --example smoke

# dev run (needs a display)
cargo tauri dev

# release build
cargo tauri build
```

`cargo tauri` requires the Tauri CLI: `npm i -g @tauri-apps/cli` (or use
`bunx @tauri-apps/cli`).

## Configuration

On first launch a default `config.json` is written to the platform config dir
(e.g. `~/.config/com.aiisdown.app/config.json` on Linux). Settings can also be
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

- The FlashDuty widget (`/api/widget/v1/summary.json`) does not expose
  component-level detail, so DeepSeek shows only overall status + incidents.
- `launch_at_login` is currently stored but not yet wired to OS autostart.
- DeepSeek's widget returns an HTTP client that rejects rustls handshakes, so
  the core uses native TLS (`default-tls`).
