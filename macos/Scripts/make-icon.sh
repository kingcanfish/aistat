#!/usr/bin/env bash
# Regenerates every app icon in the repo from Scripts/make-icon.swift:
# macos/Resources/AppIcon.icns for the native app, and src-tauri/icons/ for the
# Tauri build, so the two shells never ship different icons.
#
# Needs ImageMagick (`magick`) for the Windows .ico; everything else is stock
# macOS (swift, iconutil).
set -euo pipefail
cd "$(dirname "$0")/.."

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
swift Scripts/make-icon.swift "$TMP"

SET="$TMP/AppIcon.iconset"
mkdir "$SET"
for s in 16 32 128 256 512; do
	cp "$TMP/$s.png" "$SET/icon_${s}x${s}.png"
	cp "$TMP/$((s * 2)).png" "$SET/icon_${s}x${s}@2x.png"
done
iconutil -c icns "$SET" -o Resources/AppIcon.icns

TAURI=../src-tauri/icons
cp "$TMP/32.png" "$TAURI/32x32.png"
cp "$TMP/64.png" "$TAURI/64x64.png"
cp "$TMP/128.png" "$TAURI/128x128.png"
cp "$TMP/256.png" "$TAURI/128x128@2x.png"
cp "$TMP/512.png" "$TAURI/icon.png"
cp Resources/AppIcon.icns "$TAURI/icon.icns"
magick "$TMP/16.png" "$TMP/32.png" "$TMP/64.png" "$TMP/128.png" "$TMP/256.png" "$TAURI/icon.ico"

echo "wrote Resources/AppIcon.icns and $TAURI/"
