#!/bin/bash
# Run the signed build by hand before it ships: swap it in for the
# installed app, do one click, one scroll, one keystroke, a lode gesture
# — the acts no test on this machine can make on the real taps — then
# put the installed app back. Writes dist/.smoked, which ship.sh requires.
#
#   ./scripts/smoke.sh          in a terminal: launches, waits for enter, restores
#   ./scripts/smoke.sh start    launch the build and return (no terminal needed)
#   ./scripts/smoke.sh done     you did the acts: write the marker, restore
#   ./scripts/smoke.sh abort    restore without a marker
set -euo pipefail
cd "$(dirname "$0")/.."
APP="dist/lodestar.app"
VERSION=$(grep 'public static let version' Sources/LodestarCore/Version.swift | cut -d'"' -f2)
AGENT="$HOME/Library/LaunchAgents/com.vaccone.lodestar.plist"
MODE="${1:-interactive}"

start() {
    [ -d "$APP" ] || { echo "✕ no $APP — run ./scripts/release.sh build first"; exit 1; }
    # The installed app runs under launchd's KeepAlive; unload it or it
    # comes straight back and takes the pid file from the build under test.
    launchctl unload "$AGENT" 2>/dev/null || true
    open -n "$APP"
    echo "→ v$VERSION is running from $APP"
    echo "  do: one click · one scroll · one keystroke · a lode gesture"
}

restore() {
    launchctl load "$AGENT" 2>/dev/null || true
    echo "→ installed app restored (it takes the pid file back)"
}

mark() {
    printf '%s' "$VERSION" > dist/.smoked
    echo "✓ smoked v$VERSION — ship.sh will accept it"
}

case "$MODE" in
    start) start; echo "  then: ./scripts/smoke.sh done   (or abort)";;
    done)  mark; restore;;
    abort) restore;;
    interactive)
        if [ ! -t 0 ]; then
            echo "✕ no terminal to wait on — use: smoke.sh start, do the acts, smoke.sh done"
            exit 64
        fi
        start
        echo "  then press enter here (or ^C to abort and restore the installed app)"
        trap restore EXIT
        if read -r; then mark; fi
        ;;
    *) echo "usage: smoke.sh [start|done|abort]"; exit 64;;
esac
