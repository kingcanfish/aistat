A menu bar app that watches AI service status pages and shows an aggregate
status in your menu bar.

### Install

**macOS (Homebrew)**

```sh
brew tap kingcanfish/tap
brew install --cask aistat
```

**Manual downloads**

| Platform | File |
|---|---|
| macOS (Intel + Apple Silicon) | `.dmg` |
| Windows x86_64 | `.exe` (NSIS) or `.msi` |
| Windows arm64 | `.exe` (NSIS) |
| Linux x86_64 | `.deb`, `.rpm`, `.AppImage` |
| Linux aarch64 | `.deb`, `.rpm` |

### Unsigned builds

These builds are not code-signed.

- **macOS**: `xattr -dr com.apple.quarantine "/Applications/AIStat.app"`
- **Windows**: SmartScreen will warn — choose *More info* → *Run anyway*.
