#!/bin/bash
# The one lever on the stable channel, for a build that must not reach it.
# A release is immutable but its title is not, so a hold is a word in the
# title: "[held]". Promotion then passes over that build and every build
# of its line published before it, and the line's clock starts again at
# the next build — the fix. Stable is recomputed from scratch on every
# read, so a hold on a build already promoted steps stable back for new
# installs; Macs already on it stay (the updater never downgrades) and
# take the fix when it is promoted.
#   ./scripts/hold.sh 0.48.2           hold it
#   ./scripts/hold.sh --lift 0.48.2    take the hold off again
set -euo pipefail
cd "$(dirname "$0")/.."
REPO="${REPO:-Vaccone-Software/lodestar}"

LIFT=0
if [ "${1:-}" = "--lift" ]; then
    LIFT=1
    shift
fi
VERSION="${1:?usage: hold.sh [--lift] <version>}"
TAG="v${VERSION#v}"

TITLE=$(gh release view "$TAG" --repo "$REPO" --json name --jq .name)
if [ "$LIFT" = 1 ]; then
    NEW=$(printf '%s' "$TITLE" | sed -E 's/ ?\[[Hh][Ee][Ll][Dd]\]//g')
    [ "$NEW" != "$TITLE" ] || { echo "✓ $TAG is not held"; exit 0; }
else
    if printf '%s' "$TITLE" | grep -qi '\[held\]'; then
        echo "✓ $TAG is already held"
        exit 0
    fi
    NEW="$TITLE [held]"
fi
gh release edit "$TAG" --repo "$REPO" --title "$NEW"
echo "✓ $TAG: \"$NEW\""
./scripts/channel.sh
