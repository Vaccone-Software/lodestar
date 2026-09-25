#!/bin/sh
# The editor against real apps: TextEdit and two local Brave pages (and
# Slack, with LODESTAR_EDITOR_SLACK=1 and your own DM open). It opens
# windows and takes focus for about half a minute, so run it when the
# keyboard is free. Nothing is sent and nothing is saved.
set -e
cd "$(dirname "$0")/.."
idle=$(ioreg -c IOHIDSystem | awk '/HIDIdleTime/ {print int($NF/1000000000); exit}')
if [ "${idle:-0}" -lt 5 ] && [ -z "$FORCE" ]; then
    echo "The keyboard was used ${idle}s ago; this run takes focus. Hands off, then run again (or FORCE=1)."
    exit 1
fi
LODESTAR_EDITOR_CONFORMANCE=1 swift test --filter EditorConformanceTests 2>&1 \
    | grep -E "error:|skipped|passed|failed|Executed" | grep -v "^Test Suite 'Selected"
