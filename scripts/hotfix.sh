#!/bin/bash
# The other lever on the stable channel, for a fix that should not wait.
# Stable spares most Macs every day's build; it was never meant to hold
# back a fix. A release is immutable but its title is not, so a hotfix is
# a word in the title: "[hotfix]". The site's promotion rule (/api/stable)
# then takes that build to stable at once, with no soak and no floor, and
# the builds after it wait as usual. A hold (scripts/hold.sh) still wins.
# Stable Macs take it at their next daily check; the cask follows within
# six hours (promote.yml), or now with `gh workflow run promote.yml`.
#   ./scripts/hotfix.sh 0.48.1           send it to stable now
#   ./scripts/hotfix.sh --lift 0.48.1    take the word off again
set -euo pipefail
cd "$(dirname "$0")/.."
REPO="${REPO:-Vaccone-Software/lodestar}"

LIFT=0
if [ "${1:-}" = "--lift" ]; then
    LIFT=1
    shift
fi
VERSION="${1:?usage: hotfix.sh [--lift] <version>}"
TAG="v${VERSION#v}"

TITLE=$(gh release view "$TAG" --repo "$REPO" --json name --jq .name)
if [ "$LIFT" = 1 ]; then
    NEW=$(printf '%s' "$TITLE" | sed -E 's/ ?\[[Hh][Oo][Tt][Ff][Ii][Xx]\]//g')
    [ "$NEW" != "$TITLE" ] || { echo "✓ $TAG is not marked a hotfix"; exit 0; }
else
    if printf '%s' "$TITLE" | grep -qi '\[hotfix\]'; then
        echo "✓ $TAG is already a hotfix"
        exit 0
    fi
    NEW="$TITLE [hotfix]"
fi
gh release edit "$TAG" --repo "$REPO" --title "$NEW"
echo "✓ $TAG: \"$NEW\""
./scripts/channel.sh
