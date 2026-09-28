#!/bin/bash
# The whole ship, one command: push, notarized build, a draft release
# proven on every macOS it claims, then published, then the cask.
# Requires a notes file — a release without notes is not a release — and
# a smoke: the signed build run with a click, a scroll and a keystroke
# through its real taps (scripts/smoke.sh auto), before anything is
# pushed. --no-smoke skips the gate and says so.
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

# The smoke gate. A marker that names this version and is newer than
# the signed binary it vouches for means that binary was run and put
# through its taps; the build it vouches for is kept, not rebuilt, so the
# bytes that were smoked are the bytes that ship. No marker: build, sign,
# self-test, then smoke it here, automatically — a release no longer
# waits on a hand. --no-smoke builds and goes on.
SMOKED="dist/.smoked"
BIN="dist/lodestar.app/Contents/MacOS/lodestar"
smoked() { [ -f "$SMOKED" ] && [ -f "$BIN" ] && [ "$(cat "$SMOKED")" = "$VERSION" ] && [ "$SMOKED" -nt "$BIN" ]; }
if smoked; then
    echo "→ v$VERSION already smoked; shipping the smoked build"
else
    ./scripts/release.sh build
    if [ "${2:-}" = "--no-smoke" ]; then
        echo "→ smoke skipped by request (--no-smoke)"
    else
        echo "→ smoking v$VERSION through its real taps"
        ./scripts/smoke.sh auto || { echo "✕ the signed build failed its smoke; nothing was pushed"; exit 2; }
    fi
fi

# Pushed only once the build that ships has passed its gate.
echo "→ pushing main"
git push -q origin main

./scripts/release.sh publish

# A draft first: invisible to the updater, the site and Homebrew, and
# the one stage at which a release can still change — published releases
# are immutable. The build is started on every macOS it claims before it
# is published (verify-build.yml); 0.37.0 started only where it was built.
echo "→ drafting release v$VERSION"
gh release create "v$VERSION" "dist/lodestar-$VERSION.zip" "dist/lodestar-$VERSION.dmg" \
    $PRERELEASE --draft --title "Lodestar $VERSION" --notes-file "$NOTES" --repo "$REPO"

echo "→ starting it on macOS 14, 15 and 26 (verify-build.yml)"
SINCE=$(date -u +%Y-%m-%dT%H:%M:%SZ)
gh workflow run verify-build.yml -f tag="v$VERSION" --repo "$REPO"
RUN=""
for _ in $(seq 1 30); do
    RUN=$(gh run list --repo "$REPO" --workflow verify-build.yml --event workflow_dispatch --limit 5 \
        --json databaseId,createdAt -q "[.[] | select(.createdAt >= \"$SINCE\")][0].databaseId // empty")
    [ -n "$RUN" ] && break
    sleep 2
done
[ -n "$RUN" ] || { echo "✕ the verification run never started; v$VERSION stays a draft"; exit 1; }
if ! gh run watch "$RUN" --repo "$REPO" --exit-status >/dev/null; then
    echo "✕ v$VERSION did not start on every macOS it claims; it stays a draft (gh run view $RUN --repo $REPO)"
    exit 1
fi

echo "→ publishing release v$VERSION"
gh release edit "v$VERSION" --draft=false --repo "$REPO"

echo "→ bumping cask"
./scripts/bump-cask.sh "$VERSION" "dist/lodestar-$VERSION.zip"
echo "✓ shipped v$VERSION"
