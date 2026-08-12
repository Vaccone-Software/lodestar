#!/bin/bash
# The whole ship, one command: push, notarized build, release, cask.
# Requires a notes file — a release without notes is not a release.
#   ./scripts/ship.sh notes/v0.9.1.md
set -euo pipefail
cd "$(dirname "$0")/.."

NOTES="${1:-}"
if [ -z "$NOTES" ] || [ ! -f "$NOTES" ]; then
    echo "usage: ./scripts/ship.sh <release-notes-file>"
    exit 64
fi
if ! git diff --quiet || ! git diff --cached --quiet; then
    echo "✕ uncommitted changes — commit first"
    exit 1
fi

VERSION=$(grep 'public static let version' Sources/LodestarCore/Version.swift | cut -d'"' -f2)
REPO=Vaccone-Software/lodestar
TAP="https://github.com/Vaccone-Software/homebrew-tap.git"
PRERELEASE=""
case "$VERSION" in 0.*) PRERELEASE="--prerelease";; esac

echo "→ pushing main"
git push -q origin main

./scripts/release.sh

echo "→ publishing release v$VERSION"
gh release create "v$VERSION" "dist/lodestar-$VERSION.zip" "dist/lodestar-$VERSION.dmg" \
    $PRERELEASE --title "Lodestar $VERSION" --notes-file "$NOTES" --repo "$REPO"

echo "→ bumping cask"
SHA=$(shasum -a 256 "dist/lodestar-$VERSION.zip" | cut -d' ' -f1)
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
git -c credential.helper='!gh auth git-credential' clone -q "$TAP" "$STAGE"
python3 - "$STAGE/Casks/lodestar.rb" "$VERSION" "$SHA" <<'PY'
import re, sys
path, version, sha = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(path).read()
s = re.sub(r'version "[^"]*"', f'version "{version}"', s, count=1)
s = re.sub(r'sha256 "[^"]*"', f'sha256 "{sha}"', s, count=1)
open(path, "w").write(s)
PY
git -C "$STAGE" commit -qam "Lodestar $VERSION"
git -C "$STAGE" -c credential.helper='!gh auth git-credential' push -q origin main
echo "✓ shipped v$VERSION"
