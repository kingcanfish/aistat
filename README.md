# AIStat

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
- Left-click the tray icon to open the panel — it is anchored directly under the
  icon and dismisses itself when it loses focus, like a native menu bar popover.
  Right-click the icon for the menu (Refresh / Settings / Quit).
- The panel is a translucent vibrancy surface (NSVisualEffectView on macOS,
  Mica/Acrylic on Windows) and follows the system light/dark mode and accent
  color.
- On macOS the app runs as an accessory (`LSUIElement`): menu bar only, no Dock
  icon.
- The menu bar icon is a robot tinted with the aggregate status color; each site
  row shows the status page's own logo, scraped from its `<link rel=icon>`.
- The panel sizes itself to its content, up to a maximum, after which it scrolls.
- Configurable refresh interval (default 300s) and desktop notifications on
  status change.
- Add/remove sites from the settings panel. The adapter is **detected
  automatically** from the URL — sites that expose neither supported API are
  reported instead of being saved.
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
