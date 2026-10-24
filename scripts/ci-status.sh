#!/bin/bash
# What CI says, read from GitHub in a second and never changed: the ci.yml
# run for a commit, or how main stands.
#
#   ./scripts/ci-status.sh [sha]     the ci.yml run for sha (default HEAD)
#   ./scripts/ci-status.sh --main    only how main stands
#
# Exit status: 0 green, 1 red, 2 pending, none, or GitHub could not be
# asked. A commit with no run of its own (not pushed yet, or the run has
# not appeared) says how main stands instead: the latest completed run
# there and, when it failed, the commit since which main has been red —
# the last success is walked back to. 0.53.0 cost an afternoon because
# main had been red for two days and the first anyone heard of it was the
# ship waiting for CI on top of it. ship.sh's preflight asks both.
#
# Environment: REPO (Vaccone-Software/lodestar).
set -euo pipefail
cd "$(dirname "$0")/.."

REPO="${REPO:-Vaccone-Software/lodestar}"
BRANCH=main

ONLY_MAIN=0
SHA_ARG=""
for arg in "$@"; do
    case "$arg" in
        --main) ONLY_MAIN=1;;
        -*) echo "usage: ci-status.sh [sha | --main]"; exit 64;;
        *) SHA_ARG="$arg";;
    esac
done

# How main stands. Prints one line and returns 0 green, 1 red, 2 no
# completed run to go by. A cancelled or skipped run says nothing either
# way and is stepped over.
main_status() {
    local runs verdict
    runs=$(gh run list --repo "$REPO" --workflow ci.yml --branch "$BRANCH" --event push --status completed \
        --limit 40 --json conclusion,headSha,createdAt,url) || {
        echo "→ cannot reach GitHub to read CI on $BRANCH"
        return 2
    }
    # Newest first: the failing runs at the head of the list, the first
    # success behind them (none when the whole list is red, and then the
    # streak is "at least" as long as the list).
    verdict=$(jq -r '
        [.[] | select(.conclusion == "success" or .conclusion == "failure" or .conclusion == "timed_out" or .conclusion == "startup_failure")] as $r
        | if ($r | length) == 0 then "none"
          elif $r[0].conclusion == "success" then "green \($r[0].headSha[0:7]) \($r[0].createdAt) \($r[0].url)"
          else
            ([$r[] | .conclusion == "success"] | index(true)) as $ok
            | (if $ok == null then $r else $r[0:$ok] end) as $red
            | "red \($red[-1].headSha[0:7]) \($red[-1].createdAt) \($red[0].url) \($r[0].headSha[0:7]) \($ok == null)"
          end' <<<"$runs")
    # shellcheck disable=SC2086
    set -- $verdict
    case "$1" in
        none) echo "→ no completed ci.yml run on $BRANCH to go by"; return 2;;
        green) echo "✓ latest completed run on $BRANCH is green ($2, ${3%%T*})"; return 0;;
        red)
            local since=""
            [ "$6" = true ] && since="at least "
            echo "✕ $BRANCH has been red since ${since}$2 (${3%%T*}); latest run, on $5: $4"
            return 1;;
    esac
}

if [ "$ONLY_MAIN" = 1 ]; then
    rc=0
    main_status || rc=$?
    exit "$rc"
fi

SHA=$(git rev-parse --verify -q "${SHA_ARG:-HEAD}^{commit}") || { echo "✕ ${SHA_ARG:-HEAD} is not a commit here"; exit 64; }
SHORT="${SHA:0:7}"

# The newest push run for this commit, as: status conclusion url.
RUN=$(gh run list --repo "$REPO" --workflow ci.yml --commit "$SHA" --event push --limit 5 \
    --json status,conclusion,url -q '.[0] | if . == null then "" else "\(.status) \(if .conclusion == "" or .conclusion == null then "-" else .conclusion end) \(.url)" end') || {
    echo "→ cannot reach GitHub to read CI on $SHORT"
    exit 2
}

if [ -z "$RUN" ]; then
    echo "→ no ci.yml run for $SHORT (not pushed, or the run has not appeared yet)"
    main_status || true
    exit 2
fi

# shellcheck disable=SC2086
set -- $RUN
STATUS="$1" CONCLUSION="$2" URL="$3"
if [ "$STATUS" != completed ]; then
    echo "→ CI on $SHORT is $STATUS: $URL"
    exit 2
fi
if [ "$CONCLUSION" = success ]; then
    echo "✓ CI passed on $SHORT: $URL"
    exit 0
fi
echo "✕ CI on $SHORT ended $CONCLUSION: $URL"
exit 1
