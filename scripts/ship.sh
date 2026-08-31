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
PRERELEASE=""
case "$VERSION" in 0.*) PRERELEASE="--prerelease";; esac

echo "→ pushing main"
git push -q origin main

./scripts/release.sh

echo "→ publishing release v$VERSION"
gh release create "v$VERSION" "dist/lodestar-$VERSION.zip" "dist/lodestar-$VERSION.dmg" \
    $PRERELEASE --title "Lodestar $VERSION" --notes-file "$NOTES" --repo "$REPO"

echo "→ bumping cask"
./scripts/bump-cask.sh "$VERSION" "dist/lodestar-$VERSION.zip"
echo "✓ shipped v$VERSION"
