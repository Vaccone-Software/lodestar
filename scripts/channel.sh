#!/bin/bash
# Where the channels stand: the newest build (preview), the stable one,
# and every line still on its way with the time it has left. The same
# Promotion the stable Macs run, over the same list they read.
#   ./scripts/channel.sh                         as of now
#   ./scripts/channel.sh --now 2026-10-20T00:00:00Z   as of another moment
set -euo pipefail
cd "$(dirname "$0")/.."
REPO="${REPO:-Vaccone-Software/lodestar}"
swift build -q --product channel
gh api "repos/$REPO/releases?per_page=100" | .build/debug/channel --status "$@"
