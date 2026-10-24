#!/bin/bash
# The whole ship, one command, from main: push, notarized build, CI passed
# on the pushed commit, a draft release tagged on that commit and proven on
# every macOS it claims, then published. Published means preview: every
# Mac on the preview channel takes it at its next check. Stable follows on
# its own once the build's line has soaked, as the site decides
# (/api/stable); the cask and the download button follow stable, the cask
# through promote.yml.
# Nothing here touches stable, and nothing needs to.
# Requires a notes file — a release without notes is not a release — and
# a smoke: the signed build run with a click, a scroll and a keystroke
# through its real taps (scripts/smoke.sh auto), before anything is
# pushed. --no-smoke skips the gate and says so.
#   ./scripts/ship.sh notes/v0.9.1.md [--no-smoke]
#   ./scripts/ship.sh notes/v0.9.1.md --check
#
# The preflight runs first, on every ship, and alone with --check (the
# flags in any order). It is everything that would stop the ship, asked in
# seconds and not found after an hour of building: on main with no
# modified tracked file; the notes named for Version.swift's version,
# committed, and no tag or published release of it; local main not behind
# origin; CI green on HEAD once HEAD is on origin, and on main whatever
# HEAD is (0.53.0 got through the notes and the suite gate and then
# waited on a CI that had been red on main for two days); Stoic pinned to
# a version tag; the signing certificate and the notary profile; gh
# allowed to push; and a machine quiet enough for the smoke. Each check is
# one line, ✓ or ✕ with the command that fixes it. All of them run, then
# any ✕ stops the ship. A loaded machine is only a warning, though the
# smoke's 250 ms p99 does fail on one. The preflight builds, pushes and
# changes nothing. scripts/ci-status.sh, which it asks about CI, can be
# run on its own.
#
# It can be run again. Every network step is retried, and a ship that
# stopped — a timeout mid-upload, a laptop that slept — is resumed by the
# same command: a smoked build is kept, notarized artifacts that are still
# current are not notarized again, an empty draft release is finished
# rather than fought (scripts/github-release.sh). What it will not do is touch a release that
# is already published: that is a version bump.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=scripts/retry.sh
. scripts/retry.sh

REPO="${REPO:-Vaccone-Software/lodestar}"
USAGE="usage: ./scripts/ship.sh <release-notes-file> [--no-smoke] [--check]"
NOTES=""
CHECK_ONLY=0
SMOKE=1
for arg in "$@"; do
    case "$arg" in
        --check) CHECK_ONLY=1;;
        --no-smoke) SMOKE=0;;
        -*) echo "$USAGE"; exit 64;;
        *) NOTES="$arg";;
    esac
done
if [ -z "$NOTES" ]; then
    echo "$USAGE"
    exit 64
fi

VERSION=$(grep 'public static let version' Sources/LodestarCore/Version.swift | cut -d'"' -f2)

# The preflight. Every check runs and says one line; a ✕ is a blocker and
# carries the command that clears it, a ! is a warning the ship goes past.
# Nothing here writes: the remote is read with ls-remote (a fetch would
# move origin/main), GitHub only through calls that read.
BLOCKERS=0
ok() { echo "✓ $*"; }
note() { echo "→ $*"; }
warn() { echo "! $*"; }
blocker() {
    echo "✕ $1"
    shift
    local line
    for line in "$@"; do echo "    $line"; done
    BLOCKERS=$((BLOCKERS + 1))
}

preflight() {
    local branch notes_version remote_sha behind=0 head_pushed=0 rc out tag_line pin profile cores load

    echo "→ preflight for v$VERSION"

    # What is built is the checkout; what is pushed and tagged is main.
    # They must be the same commit, or the release names source it was not
    # built from.
    branch=$(git rev-parse --abbrev-ref HEAD)
    if [ "$branch" = main ]; then
        ok "on main"
    else
        blocker "on $branch, not main" "git switch main   (merge $branch into it first if it is not there yet)"
    fi

    if git diff --quiet && git diff --cached --quiet; then
        ok "no modified tracked files"
    else
        blocker "modified tracked files: what would be built is not what is committed" \
            "git status --short   then commit them, or git restore them"
    fi

    # What CI and the release need of the notes: named for this version,
    # not empty, and committed — `git diff` does not see an untracked
    # file, so an uncommitted notes file passes and then the verify job on
    # the clean runner cannot find it.
    notes_version=$(basename "$NOTES" .md)
    notes_version="${notes_version#v}"
    if [ ! -f "$NOTES" ]; then
        blocker "$NOTES does not exist: a release without notes is not a release" \
            "write notes/v$VERSION.md, then git add and commit it"
    elif [ ! -s "$NOTES" ]; then
        blocker "$NOTES is empty: a release without notes is not a release" "write the notes in $NOTES"
    elif ! [[ "$(basename "$NOTES")" =~ ^v[0-9]+\.[0-9]+\.[0-9]+\.md$ ]]; then
        blocker "$NOTES is not named v<version>.md, and Version.swift says $VERSION" "git mv $NOTES notes/v$VERSION.md"
    elif [ "$notes_version" != "$VERSION" ]; then
        blocker "$NOTES is for $notes_version, and Version.swift says $VERSION" \
            "sed -i '' 's/public static let version = \"$VERSION\"/public static let version = \"$notes_version\"/' Sources/LodestarCore/Version.swift" \
            "git commit -am 'Version $notes_version with its notes'   (the notes file in the same commit: git add $NOTES first)"
    elif ! git ls-files --error-unmatch "$NOTES" >/dev/null 2>&1; then
        blocker "$NOTES is not committed — CI will not find it" "git add $NOTES && git commit -m 'Version $VERSION with its notes'"
    else
        ok "$NOTES matches Version.swift ($VERSION) and is committed"
    fi

    # Is this version already out? Published releases are immutable. A
    # draft is not a blocker: a stopped ship's draft is finished.
    tag_line=""
    if git rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null; then
        tag_line="the tag v$VERSION already exists here"
    fi
    rc=0
    out=$(RELEASE_TRIES=1 ./scripts/github-release.sh check "$VERSION" 2>&1) || rc=$?
    case "$rc" in
        0)
            if [ -n "$tag_line" ]; then
                blocker "$tag_line" "git tag -d v$VERSION   if it is a stale local tag; otherwise bump the version"
            elif git ls-remote --exit-code --tags origin "refs/tags/v$VERSION" >/dev/null 2>&1; then
                blocker "the tag v$VERSION is already on origin" \
                    "bump the version: sed -i '' 's/public static let version = \"$VERSION\"/public static let version = \"<new>\"/' Sources/LodestarCore/Version.swift" \
                    "write notes/v<new>.md, commit 'Version <new> with its notes'"
            else
                ok "v$VERSION is not tagged or published"
            fi
            grep -F "draft of" <<<"$out" | sed 's/^/  /' || true;;
        1)
            blocker "v$VERSION is already published, and published releases are immutable" \
                "bump the version: sed -i '' 's/public static let version = \"$VERSION\"/public static let version = \"<new>\"/' Sources/LodestarCore/Version.swift" \
                "write notes/v<new>.md, commit 'Version <new> with its notes'";;
        *)
            blocker "cannot reach GitHub to look for v$VERSION" "check the network, then gh auth status";;
    esac

    # Local main against origin's, read without fetching.
    if remote_sha=$(git ls-remote origin refs/heads/main 2>/dev/null | cut -f1) && [ -n "$remote_sha" ]; then
        if [ "$remote_sha" = "$(git rev-parse HEAD)" ]; then
            ok "main is origin/main"
            head_pushed=1
        elif git merge-base --is-ancestor "$remote_sha" HEAD 2>/dev/null; then
            note "main is ahead of origin/main: ship will push it, and CI will run on the new commit"
        elif git cat-file -e "$remote_sha^{commit}" 2>/dev/null && git merge-base --is-ancestor HEAD "$remote_sha"; then
            behind=1
            blocker "main is behind origin/main" "git pull --ff-only"
        else
            behind=1
            blocker "main and origin/main have diverged, or origin has commits not fetched here" \
                "git fetch origin && git pull --ff-only   (rebase if they diverged)"
        fi
    else
        behind=1
        blocker "cannot read origin/main" "check the network and the origin remote"
    fi

    # CI. The commit's own run when it is on origin; and, whatever HEAD
    # is, how main stands: a red main is what the ship would otherwise
    # find out after the whole build.
    if [ "$head_pushed" = 1 ]; then
        rc=0
        out=$(./scripts/ci-status.sh HEAD 2>&1) || rc=$?
        case "$rc" in
            0) ok "${out#* }";;
            1) blocker "${out#* }" "fix it, commit, and ship again";;
            *) warn "${out#* }"; echo "    ship will wait for it";;
        esac
    elif [ "$behind" = 0 ]; then
        note "HEAD is not on origin yet: CI has not run on it"
    fi
    rc=0
    out=$(./scripts/ci-status.sh --main 2>&1) || rc=$?
    case "$rc" in
        0) ok "${out#* }";;
        1) blocker "${out#* }" "fix main and let CI go green first: ./scripts/ci-status.sh --main";;
        *) warn "${out#* }";;
    esac

    # What the build links, from the lockfile: Stoic by a version tag. A
    # branch or a bare revision moves under a rebuild, and Stoic's own
    # releases are the ones that were tested together.
    pin=$(awk '/"identity" *: *"stoic"/ {f = 1} f && /"state"/ {s = 1} f && s {print} f && s && /}/ {exit}' Package.resolved)
    if [ -z "$pin" ]; then
        blocker "Stoic is not in Package.resolved" "swift package resolve, and commit Package.resolved"
    elif grep -q '"version"' <<<"$pin" && ! grep -q '"branch"' <<<"$pin"; then
        ok "Stoic is pinned to $(sed -n 's/.*"version" *: *"\(.*\)".*/\1/p' <<<"$pin")"
    else
        blocker "Stoic is pinned to a branch or a revision, not a version tag" \
            "in Package.swift: .package(url: \".../stoic\", .upToNextMinor(from: \"<tag>\"), ...), then swift package update stoic, and commit Package.resolved"
    fi

    # What the signing and the notarization need, as release.sh reads
    # them: the Developer ID certificate, and the notary profile, asked
    # with the call release.sh makes (it reads the submission history and
    # prints no credential). A missing profile, an agreement not accepted
    # or a revoked password would otherwise stop the ship after the build.
    profile=$(sed -n 's/^PROFILE=//p' scripts/release.sh | head -1)
    profile="${profile:-lodestar-notary}"
    if security find-identity -v -p codesigning 2>/dev/null | grep -q "Developer ID Application"; then
        ok "a Developer ID Application certificate is in the keychain"
    else
        blocker "no 'Developer ID Application' certificate in the keychain" \
            "Xcode → Settings → Accounts → Manage Certificates → + → Developer ID Application"
    fi
    if out=$(xcrun notarytool history --keychain-profile "$profile" 2>&1); then
        ok "the notary profile '$profile' answers"
    else
        blocker "the notary profile '$profile' does not work: $(head -1 <<<"$out")" \
            "xcrun notarytool store-credentials $profile --apple-id <you> --team-id <TEAMID> --password <app-specific-pw>" \
            "(or an agreement to accept at https://developer.apple.com/account)"
    fi

    # The push and the release are made as whoever gh is.
    if [ "$(gh api "repos/$REPO" -q .permissions.push 2>/dev/null)" = true ]; then
        ok "gh can push to $REPO"
    else
        blocker "gh is not signed in to an account that can push to $REPO" "gh auth status   then gh auth login, or gh auth switch"
    fi

    # The smoke holds the app to a 250 ms p99, which a Mac busy with
    # something else cannot give.
    cores=$(sysctl -n hw.ncpu)
    load=$(sysctl -n vm.loadavg | awk '{print $2}')
    if awk -v l="$load" -v c="$cores" 'BEGIN { exit !(l > c) }'; then
        warn "the machine is loaded (1-minute load $load on $cores cores): the smoke gate's 250 ms p99 fails on a loaded Mac; quit what is running, or wait"
    else
        ok "the machine is quiet enough for the smoke (1-minute load $load on $cores cores)"
    fi
}

preflight
if [ "$BLOCKERS" -gt 0 ]; then
    echo "✕ $BLOCKERS blocker$([ "$BLOCKERS" -eq 1 ] || echo s): nothing was built, pushed or published"
    exit 1
fi
echo "✓ preflight passed"
[ "$CHECK_ONLY" = 1 ] && exit 0

# What is built is the checkout; what is pushed and tagged is main. The
# preflight made sure they are the same commit.
COMMIT=$(git rev-parse HEAD)

STEP="starting"
trap 'rc=$?; [ "$rc" -eq 0 ] || echo "✕ ship stopped at: $STEP. Once that is sorted, run the same command again: it picks up from there." >&2' EXIT

# The smoke gate. A marker that names this version and is newer than
# the signed binary it vouches for means that binary was run and put
# through its taps; the build it vouches for is kept, not rebuilt, so the
# bytes that were smoked are the bytes that ship. No marker: build, sign,
# self-test, then smoke it here, automatically — a release no longer
# waits on a hand. --no-smoke builds and goes on.
STEP="building and smoking"
SMOKED="dist/.smoked"
BIN="dist/lodestar.app/Contents/MacOS/lodestar"
# The commit the signed build was made from. A build, a smoke and a
# notarization are kept across a stopped ship only while they were made
# from this commit: a fix committed after a failed CI, at the same
# version, would otherwise ship the old bytes under a tag naming the fix.
BUILT_FROM="dist/.built-from"
# release.sh build writes it, from a clean tree only.
built_here() { [ -f "$BUILT_FROM" ] && [ "$(cat "$BUILT_FROM")" = "$COMMIT" ]; }
smoked() { built_here && [ -f "$SMOKED" ] && [ -f "$BIN" ] && [ "$(cat "$SMOKED")" = "$VERSION" ] && [ "$SMOKED" -nt "$BIN" ]; }
if smoked; then
    echo "→ v$VERSION already smoked; shipping the smoked build"
else
    ./scripts/release.sh build
    if [ "$SMOKE" = 0 ]; then
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
    built_here && [ -f "$ZIP" ] && [ -f "$DMG" ] && [ "$ZIP" -nt "$BIN" ] && [ "$DMG" -nt "$BIN" ] \
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

echo "✓ shipped v$VERSION to preview; stable follows on its own"
./scripts/channel.sh || true
