#!/usr/bin/env bash
# Cuts a release: bumps the version, commits, tags and pushes.
#
# Cargo.toml's [workspace.package] version is the single source of truth —
# tauri.conf.json has no version field, so Tauri reads it from there, and CI
# refuses to build a tag that disagrees with it. This script keeps the two in
# step so that check never fires.
#
#   usage: scripts/release.sh 0.2.0
set -euo pipefail

VERSION="${1:-}"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-+].+)?$ ]]; then
  echo "usage: $0 <version>   e.g. $0 0.2.0" >&2
  exit 1
fi

cd "$(dirname "$0")/.."

if [ -n "$(git status --porcelain)" ]; then
  echo "error: working tree is dirty; commit or stash first." >&2
  exit 1
fi

BRANCH="$(git rev-parse --abbrev-ref HEAD)"
if [ "$BRANCH" != "main" ]; then
  echo "error: releases are cut from main, not '$BRANCH'." >&2
  exit 1
fi

if git rev-parse "v$VERSION" >/dev/null 2>&1; then
  echo "error: tag v$VERSION already exists." >&2
  exit 1
fi

CURRENT="$(python3 - <<'PY'
import re, pathlib
text = pathlib.Path("Cargo.toml").read_text()
block = re.search(r"\[workspace\.package\](.*?)(?=\n\[|\Z)", text, re.S).group(1)
print(re.search(r'version\s*=\s*"([^"]+)"', block).group(1))
PY
)"

echo "  $CURRENT -> $VERSION"

python3 - "$VERSION" <<'PY'
import re, sys, pathlib
version = sys.argv[1]
path = pathlib.Path("Cargo.toml")
text = path.read_text()
start = text.index("[workspace.package]")
end = text.find("\n[", start + 1)
end = len(text) if end == -1 else end
block = text[start:end]
updated = re.sub(r'(version\s*=\s*)"[^"]+"', rf'\1"{version}"', block, count=1)
path.write_text(text[:start] + updated + text[end:])
PY

# Refresh Cargo.lock so the recorded package versions match.
cargo metadata --no-deps --format-version 1 >/dev/null

git add Cargo.toml Cargo.lock
git commit -m "Release v$VERSION"
git tag -a "v$VERSION" -m "AIStat v$VERSION"

echo
echo "Tagged v$VERSION. Push to start the release build:"
echo "  git push origin main --follow-tags"
