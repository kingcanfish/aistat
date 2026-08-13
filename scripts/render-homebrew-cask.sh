#!/usr/bin/env bash
# Renders the Homebrew cask for AIStat.
#
# A cask rather than a formula: AIStat is a GUI .app bundle, not a CLI binary.
# The dmg is universal, so one url/sha256 pair covers Intel and Apple Silicon.
#
#   usage: render-homebrew-cask.sh <version> <dmg-url> <dmg-sha256>
set -euo pipefail

VERSION="${1:?version required}"
URL="${2:?dmg url required}"
SHA256="${3:?dmg sha256 required}"

# The URL embeds the version, so write it back as an interpolation: Homebrew's
# `brew livecheck` and version bumps then only have to touch `version`. The
# replacement is held in a variable because escaping `}` inline leaks the
# backslash into the output.
INTERPOLATION='#{version}'
URL_TEMPLATE="${URL//$VERSION/$INTERPOLATION}"

cat <<CASK
cask "aistat" do
  version "${VERSION}"
  sha256 "${SHA256}"

  url "${URL_TEMPLATE}",
      verified: "github.com/kingcanfish/aistat/"
  name "AIStat"
  desc "Menu bar app that watches AI service status pages"
  homepage "https://github.com/kingcanfish/aistat"

  depends_on macos: ">= :big_sur"

  app "AIStat.app"

  zap trash: [
    "~/Library/Application Support/com.aistat.app",
    "~/Library/Caches/com.aistat.app",
    "~/Library/Saved Application State/com.aistat.app.savedState",
  ]

  caveats <<~EOS
    AIStat is not signed with an Apple Developer ID, so Gatekeeper will refuse
    to open it on first launch. Clear the quarantine flag once:

      xattr -dr com.apple.quarantine "/Applications/AIStat.app"

    AIStat runs in the menu bar only and has no Dock icon.
  EOS
end
CASK
