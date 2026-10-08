#!/bin/bash
# The GitHub half of a ship: a draft release, its two artifacts, the
# verification on every macOS the build claims, and the publish. Every
# step can be repeated and every network call is retried, so a timeout in
# the middle is a delay, and a ship that stopped is resumed by running
# ship.sh again.
#
# It exists because 0.39.4 died uploading its zip: `gh release create`
# made the draft, the upload timed out, and the empty draft that was left
# made every later `gh release create` fail with "already exists". Now:
#
#   - The draft is made bare and looked for first: an empty draft from a
#     stopped ship is finished, not fought. A create that errored after
#     the server made it is found, not repeated.
#   - Each artifact is uploaded on its own and only counts once GitHub
#     lists it whole (name and byte size match the file). One that landed
#     but errored is not sent again; one that half-landed is replaced.
#   - The verification run is waited on by asking, not by holding one
#     connection open: a blip while waiting is one missed question.
#   - A release already published is never touched: published releases
#     are immutable, and the answer is a version bump.
#
#   ./scripts/github-release.sh check   <version>
#   ./scripts/github-release.sh ci      <version> <commit>
#   ./scripts/github-release.sh publish <version> <notes-file> <zip> <dmg>
#
# `check` is what ship.sh asks before it spends minutes building. Exit
# status: 0 fine, 1 a real problem, 2 GitHub could not be reached.
#
# `ci` waits for the CI run on the commit being shipped and fails unless it
# passed. 0.44.0, 0.45.0 and 0.45.1 shipped while CI was red, because
# nothing between the push and the publish ever read it.
#
# Environment: REPO (Vaccone-Software/lodestar), RELEASE_TRIES,
# RELEASE_RETRY_DELAY (see retry.sh), RELEASE_POLL_DELAY (20 s between
# looks at the verification), RELEASE_FIND_DELAY (2 s while the run
# appears), RELEASE_VERIFY_SECONDS (3600), RELEASE_CI_SECONDS (1800),
# RELEASE_TARGET (the commit the tag is made on, so the tag names the
# source that was built and not whatever the default branch holds).
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=scripts/retry.sh
. scripts/retry.sh

REPO="${REPO:-Vaccone-Software/lodestar}"
POLL_DELAY="${RELEASE_POLL_DELAY:-20}"
FIND_DELAY="${RELEASE_FIND_DELAY:-2}"
VERIFY_SECONDS="${RELEASE_VERIFY_SECONDS:-3600}"

MODE="${1:-}"
VERSION="${2:-}"
[ -n "$MODE" ] && [ -n "$VERSION" ] || {
    echo "usage: github-release.sh check <version> | publish <version> <notes> <zip> <dmg>"
    exit 64
}
TAG="v$VERSION"
PRERELEASE=""
case "$VERSION" in 0.*) PRERELEASE="--prerelease";; esac

RELEASE_ID=""
RELEASE_STATE="none"

# Sets RELEASE_ID and RELEASE_STATE (none, draft or published) from the
# newest releases, drafts included (they are only in the list, never at
# releases/tags/). Nonzero only when GitHub could not be asked.
lookup_release() {
    local line
    line=$(gh api "repos/$REPO/releases?per_page=30" \
        --jq "[.[] | select(.tag_name == \"$TAG\")][0] | if . == null then \"none\" else \"\(.id) \(if .draft then \"draft\" else \"published\" end)\" end") || return 1
    if [ "$line" = none ]; then
        RELEASE_ID=""
        RELEASE_STATE="none"
    else
        RELEASE_ID="${line% *}"
        RELEASE_STATE="${line#* }"
    fi
}

case "$MODE" in
check)
    retry lookup_release || { echo "✕ cannot reach GitHub to look for $TAG; nothing was built or published"; exit 2; }
    case "$RELEASE_STATE" in
        published)
            echo "✕ $TAG is already published, and published releases are immutable: bump Lodestar.version and write notes/v<new>.md"
            echo "  (if only its cask bump is left: ./scripts/bump-cask.sh $VERSION dist/lodestar-$VERSION.zip, which is safe to repeat)"
            exit 1;;
        draft) echo "→ a draft of $TAG is already on GitHub (an earlier ship stopped); this ship will finish it";;
    esac
    exit 0
    ;;
ci)
    COMMIT="${3:?commit}"
    CI_SECONDS="${RELEASE_CI_SECONDS:-1800}"
    find_ci() {
        CI_RUN=$(gh run list --repo "$REPO" --workflow ci.yml --commit "$COMMIT" --event push --limit 5 \
            --json databaseId -q '.[0].databaseId // empty') || return 1
        [ -n "$CI_RUN" ]
    }
    CI_RUN=""
    deadline=$((SECONDS + CI_SECONDS))
    echo "→ waiting for CI on ${COMMIT:0:7}"
    while [ "$SECONDS" -lt "$deadline" ]; do
        find_ci 2>/dev/null && break
        sleep "$FIND_DELAY"
    done
    [ -n "$CI_RUN" ] || { echo "✕ no CI run for ${COMMIT:0:7} appeared in ${CI_SECONDS}s; nothing was published"; exit 1; }
    echo "  run $CI_RUN"
    answer=""
    while [ "$SECONDS" -lt "$deadline" ]; do
        answer=$(gh run view "$CI_RUN" --repo "$REPO" --json status,conclusion \
            --jq 'if .status == "completed" then .conclusion else "" end' 2>/dev/null) || answer=""
        [ -n "$answer" ] && break
        sleep "$POLL_DELAY"
    done
    case "$answer" in
        success) echo "✓ CI passed on ${COMMIT:0:7}"; exit 0;;
        "") echo "✕ CI on ${COMMIT:0:7} did not finish in ${CI_SECONDS}s; nothing was published (gh run view $CI_RUN --repo $REPO)"; exit 1;;
        *) echo "✕ CI on ${COMMIT:0:7} ended $answer; nothing was published. Fix it, commit, and ship again (gh run view $CI_RUN --repo $REPO)"; exit 1;;
    esac
    ;;
publish) ;;
*) echo "usage: github-release.sh check <version> | ci <version> <commit> | publish <version> <notes> <zip> <dmg>"; exit 64;;
esac

NOTES="${3:?notes file}"
ZIP="${4:?zip}"
DMG="${5:?dmg}"
for f in "$NOTES" "$ZIP" "$DMG"; do
    [ -f "$f" ] || { echo "✕ $f is missing"; exit 1; }
done

REUSED=0
# A draft for the tag, made if there is none. A create that timed out may
# still have made the draft, so a failed create is followed by a look, not
# by a second create.
ensure_draft() {
    lookup_release || return 1
    if [ "$RELEASE_STATE" = none ]; then
        gh release create "$TAG" $PRERELEASE --draft --title "Lodestar $VERSION" \
            ${RELEASE_TARGET:+--target "$RELEASE_TARGET"} \
            --notes-file "$NOTES" --repo "$REPO" >/dev/null || true
        lookup_release || return 1
        [ "$RELEASE_STATE" != none ]
    else
        REUSED=1
    fi
}

# Whether GitHub lists this file whole: the name and the byte size.
asset_ok() {
    local listing
    listing=$(gh api "repos/$REPO/releases/$RELEASE_ID" \
        --jq '.assets[] | select(.state == "uploaded") | "\(.name) \(.size)"') || return 1
    grep -qxF "$(basename "$1") $(stat -f %z "$1")" <<<"$listing"
}

# Each artifact on the draft, whole. `--clobber` replaces a half-sent one;
# a whole one is not sent again, whatever the last error said.
upload_assets() {
    local f
    for f in "$ZIP" "$DMG"; do
        asset_ok "$f" && continue
        echo "  uploading $(basename "$f")" >&2
        gh release upload "$TAG" "$f" --repo "$REPO" --clobber >/dev/null || true
    done
    for f in "$ZIP" "$DMG"; do
        asset_ok "$f" || return 1
    done
}

VERIFY_SINCE=""
dispatch_verify() {
    gh workflow run verify-build.yml -f tag="$TAG" --repo "$REPO" >/dev/null
}

RUN=""
find_run() {
    RUN=$(gh run list --repo "$REPO" --workflow verify-build.yml --event workflow_dispatch --limit 5 \
        --json databaseId,createdAt \
        -q "[.[] | select(.createdAt >= \"$VERIFY_SINCE\")][0].databaseId // empty") || return 1
    [ -n "$RUN" ]
}

# Asks until the run has finished, tolerating questions that fail.
VERIFY_RESULT=""
wait_for_verify() {
    local deadline=$((SECONDS + VERIFY_SECONDS)) answer
    VERIFY_RESULT=""
    while [ "$SECONDS" -lt "$deadline" ]; do
        answer=$(gh run view "$RUN" --repo "$REPO" --json status,conclusion \
            --jq 'if .status == "completed" then .conclusion else "" end' 2>/dev/null) || answer=""
        if [ -n "$answer" ]; then
            VERIFY_RESULT="$answer"
            return 0
        fi
        sleep "$POLL_DELAY"
    done
    return 1
}

echo "→ drafting release $TAG"
retry ensure_draft || { echo "✕ could not reach GitHub to make the draft; nothing was published. Run ship.sh again."; exit 1; }
if [ "$RELEASE_STATE" = published ]; then
    echo "✕ $TAG is already published, and published releases are immutable: bump Lodestar.version and write notes/v<new>.md"
    exit 1
fi
if [ "$REUSED" = 1 ]; then
    echo "  the draft was already there; refreshing its notes and title"
    retry gh release edit "$TAG" $PRERELEASE --title "Lodestar $VERSION" --notes-file "$NOTES" \
        --repo "$REPO" >/dev/null || { echo "✕ could not refresh the draft's notes. Run ship.sh again."; exit 1; }
fi

echo "→ uploading the notarized artifacts"
retry upload_assets || { echo "✕ the artifacts did not all reach GitHub; $TAG stays a draft. Run ship.sh again: it picks up from here."; exit 1; }

echo "→ starting it on macOS 14, 15 and 26 (verify-build.yml)"
VERIFY_SINCE=$(date -u +%Y-%m-%dT%H:%M:%SZ)
retry dispatch_verify || { echo "✕ the verification run could not be started; $TAG stays a draft. Run ship.sh again."; exit 1; }
for _ in $(seq 1 30); do
    find_run 2>/dev/null && break
    sleep "$FIND_DELAY"
done
[ -n "$RUN" ] || { echo "✕ the verification run never appeared; $TAG stays a draft"; exit 1; }
echo "  run $RUN"
wait_for_verify || { echo "✕ the verification run did not finish in ${VERIFY_SECONDS}s or could not be read; $TAG stays a draft (gh run view $RUN --repo $REPO)"; exit 1; }
if [ "$VERIFY_RESULT" != success ]; then
    echo "✕ $TAG did not start on every macOS it claims ($VERIFY_RESULT); it stays a draft (gh run view $RUN --repo $REPO)"
    exit 1
fi

echo "→ publishing release $TAG"
retry gh release edit "$TAG" --draft=false --repo "$REPO" >/dev/null \
    || { echo "✕ could not publish $TAG; it is verified and stays a draft. Run ship.sh again."; exit 1; }
echo "✓ $TAG is published"
