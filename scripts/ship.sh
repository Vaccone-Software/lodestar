#!/bin/bash
# The whole ship, one command: push, notarized build, release, cask.
# Requires a notes file — a release without notes is not a release — and
# a smoke: the signed build run by a hand (scripts/smoke.sh) for one
# click, one scroll, one keystroke, because no test on this machine can
# stand in for that. --no-smoke skips the gate and says so.
#   ./scripts/ship.sh notes/v0.9.1.md [--no-smoke]
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

# The smoke gate. A marker that names this version and is newer than
# the signed binary it vouches for means a hand ran that binary; the
# build it vouches for is kept, not rebuilt, so the bytes that were
# smoked are the bytes that ship. No marker: build, sign, self-test,
# then stop here with instructions. --no-smoke builds and goes on.
SMOKED="dist/.smoked"
BIN="dist/lodestar.app/Contents/MacOS/lodestar"
smoked() { [ -f "$SMOKED" ] && [ -f "$BIN" ] && [ "$(cat "$SMOKED")" = "$VERSION" ] && [ "$SMOKED" -nt "$BIN" ]; }
if smoked; then
    echo "→ smoked v$VERSION by hand; shipping the smoked build"
else
    ./scripts/release.sh build
    if [ "${2:-}" = "--no-smoke" ]; then
        echo "→ smoke skipped by request (--no-smoke)"
    else
        echo "✕ not smoked: run ./scripts/smoke.sh, do one click, one scroll, one keystroke, then ship again"
        exit 2
    fi
fi

./scripts/release.sh publish

echo "→ publishing release v$VERSION"
gh release create "v$VERSION" "dist/lodestar-$VERSION.zip" "dist/lodestar-$VERSION.dmg" \
    $PRERELEASE --title "Lodestar $VERSION" --notes-file "$NOTES" --repo "$REPO"

echo "→ bumping cask"
./scripts/bump-cask.sh "$VERSION" "dist/lodestar-$VERSION.zip"
echo "✓ shipped v$VERSION"
