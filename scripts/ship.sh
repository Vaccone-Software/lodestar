#!/bin/bash
# The whole ship, one command, from main: push, notarized build, CI passed
# on the pushed commit, a draft release tagged on that commit and proven on
# every macOS it claims, then published, then the cask.
# Requires a notes file — a release without notes is not a release — and
# a smoke: the signed build run with a click, a scroll and a keystroke
# through its real taps (scripts/smoke.sh auto), before anything is
# pushed. --no-smoke skips the gate and says so.
#   ./scripts/ship.sh notes/v0.9.1.md [--no-smoke]
#
# It can be run again. Every network step is retried, and a ship that
# stopped — a timeout mid-upload, a laptop that slept — is resumed by the
# same command: a smoked build is kept, notarized artifacts that are still
# current are not notarized again, an empty draft release is finished
# rather than fought (scripts/github-release.sh), and a cask already at
# this version is left alone. What it will not do is touch a release that
# is already published: that is a version bump.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=scripts/retry.sh
. scripts/retry.sh

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

# What is built is the checkout; what is pushed and tagged is main. They
# must be the same commit, or the release names source it was not built
# from.
COMMIT=$(git rev-parse HEAD)
if [ "$COMMIT" != "$(git rev-parse main)" ]; then
    echo "✕ HEAD is $(git rev-parse --abbrev-ref HEAD), not main: merge into main and ship from there"
    exit 1
fi

# What CI and the release need of the notes, found out now and not after a
# notarized build: named for this version, and committed — `git diff` does
# not see an untracked file, so an uncommitted notes file passes here and
# then the verify job on the clean runner cannot find it.
if [ "$(basename "$NOTES")" != "v$VERSION.md" ]; then
    echo "✕ $NOTES is not notes/v$VERSION.md, and Version.swift says $VERSION"
    exit 1
fi
if ! git ls-files --error-unmatch "$NOTES" >/dev/null 2>&1; then
    echo "✕ $NOTES is not committed — CI will not find it. git add and commit it first"
    exit 1
fi

STEP="starting"
trap 'rc=$?; [ "$rc" -eq 0 ] || echo "✕ ship stopped at: $STEP. Once that is sorted, run the same command again: it picks up from there." >&2' EXIT

# Before minutes of building: is this version already out (published
# releases are immutable), and can GitHub be reached at all?
STEP="looking for v$VERSION on GitHub"
./scripts/github-release.sh check "$VERSION"

# The smoke gate. A marker that names this version and is newer than
# the signed binary it vouches for means that binary was run and put
# through its taps; the build it vouches for is kept, not rebuilt, so the
# bytes that were smoked are the bytes that ship. No marker: build, sign,
# self-test, then smoke it here, automatically — a release no longer
# waits on a hand. --no-smoke builds and goes on.
STEP="building and smoking"
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
STEP="pushing main"
echo "→ pushing main"
retry git push -q origin main
if [ "$(git rev-parse origin/main)" != "$COMMIT" ]; then
    echo "✕ origin/main is not ${COMMIT:0:7} after the push"
    exit 1
fi

# Notarized artifacts left by a ship that stopped later are kept when they
# are still the ones for this binary: newer than it, and both stapled.
# Notarizing again is minutes for the same bytes.
ZIP="dist/lodestar-$VERSION.zip"
DMG="dist/lodestar-$VERSION.dmg"
artifacts_current() {
    [ -f "$ZIP" ] && [ -f "$DMG" ] && [ "$ZIP" -nt "$BIN" ] && [ "$DMG" -nt "$BIN" ] \
        && xcrun stapler validate dist/lodestar.app >/dev/null 2>&1 \
        && xcrun stapler validate "$DMG" >/dev/null 2>&1
}
STEP="notarizing"
if artifacts_current; then
    echo "→ notarized v$VERSION artifacts from an earlier run are current; not notarizing again"
else
    ./scripts/release.sh publish
fi

# A draft first: invisible to the updater, the site and Homebrew, and
# the one stage at which a release can still change — published releases
# are immutable. The build is started on every macOS it claims before it
# is published (verify-build.yml); 0.37.0 started only where it was built.
# All of it, retried and resumable, is github-release.sh.
# CI on the pushed commit ran while this one notarized. Nothing is drafted
# until it passes. SHIP_SKIP_CI=1 is for a CI that cannot run at all (a
# GitHub outage), never for one that failed.
STEP="waiting for CI"
if [ "${SHIP_SKIP_CI:-}" = 1 ]; then
    echo "→ CI not waited for (SHIP_SKIP_CI=1)"
else
    ./scripts/github-release.sh ci "$VERSION" "$COMMIT"
fi

STEP="the GitHub release"
RELEASE_TARGET="$COMMIT" ./scripts/github-release.sh publish "$VERSION" "$NOTES" "$ZIP" "$DMG"

STEP="bumping the cask"
echo "→ bumping cask"
retry ./scripts/bump-cask.sh "$VERSION" "$ZIP"
echo "✓ shipped v$VERSION"
