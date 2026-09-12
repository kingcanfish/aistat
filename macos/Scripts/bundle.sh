#!/usr/bin/env bash
# Assembles AIStat.app around the SwiftPM executable, and optionally a dmg.
#
# SwiftPM builds a bare Mach-O; three of the app's behaviours need a real
# bundle around it and will quietly do nothing without one:
#
#   * LSUIElement — menu bar only, no Dock icon, no app switcher entry;
#   * UNUserNotificationCenter — refuses to post for a process with no
#     Launch Services-registered bundle identifier;
#   * SMAppService.mainApp — has nothing to register as a login item.
#
# The signature is ad-hoc (`-`). That is enough for all three, including the
# login item — measured: register() and unregister() both succeed against an
# ad-hoc signed bundle. What it is *not* enough for is Gatekeeper, so a
# downloaded build still needs its quarantine flag cleared once; the Homebrew
# cask says so in its caveats. Set CODESIGN_IDENTITY to a Developer ID to make
# that caveat unnecessary.
#
#   usage: Scripts/bundle.sh
#   env:   UNIVERSAL=1          build arm64 + x86_64 (release CI does)
#          DMG=1                also produce AIStat_<version>_universal.dmg
#          CONFIGURATION=debug  default is release
#          CODESIGN_IDENTITY    default is "-" (ad-hoc)
#          VERSION              overrides the version; see below
#          OUT_DIR              default .build/bundle
set -euo pipefail

cd "$(dirname "$0")/.."

CONFIGURATION="${CONFIGURATION:-release}"
IDENTITY="${CODESIGN_IDENTITY:--}"
APP_NAME="AIStat"
BUNDLE_ID="com.aistat.app"
OUT_DIR="${OUT_DIR:-.build/bundle}"
APP="$OUT_DIR/$APP_NAME.app"

# The version lives in the Rust workspace manifest one directory up, which is
# what the release workflow validates the tag against. Standalone checkouts of
# just this package have no such file and get a placeholder.
if [ -z "${VERSION:-}" ]; then
  if [ -f ../Cargo.toml ]; then
    VERSION="$(sed -n '/^\[workspace.package\]/,/^\[/s/^version *= *"\(.*\)"/\1/p' ../Cargo.toml | head -1)"
  fi
fi
VERSION="${VERSION:-0.0.0}"

ARCH_ARGS=()
if [ "${UNIVERSAL:-0}" = "1" ]; then
  ARCH_ARGS=(--arch arm64 --arch x86_64)
fi
# macOS ships bash 3.2, where `"${empty[@]}"` under `set -u` is an unbound
# variable rather than zero arguments. The `+` expansion is the portable way to
# say "these arguments, if there are any".
ARCH=(${ARCH_ARGS[@]+"${ARCH_ARGS[@]}"})

echo "==> Building $APP_NAME $VERSION ($CONFIGURATION${UNIVERSAL:+, universal})"
swift build -c "$CONFIGURATION" ${ARCH[@]+"${ARCH[@]}"} --product "$APP_NAME"
BIN_PATH="$(swift build -c "$CONFIGURATION" ${ARCH[@]+"${ARCH[@]}"} --product "$APP_NAME" --show-bin-path)"
BINARY="$BIN_PATH/$APP_NAME"

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/$APP_NAME"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key>
	<string>$APP_NAME</string>
	<key>CFBundleDisplayName</key>
	<string>$APP_NAME</string>
	<key>CFBundleExecutable</key>
	<string>$APP_NAME</string>
	<key>CFBundleIdentifier</key>
	<string>$BUNDLE_ID</string>
	<key>CFBundleIconFile</key>
	<string>AppIcon</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<!-- Read back at runtime as AIStatCore.version, so the number the app
	     reports and the number a status page sees cannot disagree. -->
	<key>CFBundleShortVersionString</key>
	<string>$VERSION</string>
	<key>CFBundleVersion</key>
	<string>$VERSION</string>
	<key>LSMinimumSystemVersion</key>
	<string>14.0</string>
	<!-- Menu bar only: no Dock icon, no app switcher entry. -->
	<key>LSUIElement</key>
	<true/>
	<key>NSHighResolutionCapable</key>
	<true/>
</dict>
</plist>
PLIST

echo "==> Signing ($IDENTITY)"
codesign --force --sign "$IDENTITY" --timestamp=none "$APP"
codesign --verify --verbose=1 "$APP"

if [ "${DMG:-0}" = "1" ]; then
  DMG_PATH="$OUT_DIR/${APP_NAME}_${VERSION}_universal.dmg"
  echo "==> Packing $DMG_PATH"
  rm -f "$DMG_PATH"
  # A plain compressed image: the Homebrew cask copies AIStat.app out of it, so
  # a decorated window with an /Applications alias would only matter to someone
  # opening the dmg by hand.
  hdiutil create -volname "$APP_NAME" -srcfolder "$APP" -ov -format UDZO "$DMG_PATH" >/dev/null
  echo "    $(shasum -a 256 "$DMG_PATH" | awk '{print $1}')"
fi

echo "==> Done: $APP"
