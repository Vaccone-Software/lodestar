#!/bin/bash
# Run the signed build by hand before it ships: swap it in for the
# installed app, do one click, one scroll, one keystroke — the three acts
# no test on this machine can make on the real taps — then put the
# installed app back. Writes dist/.smoked, which ship.sh requires.
#   ./scripts/smoke.sh
set -euo pipefail
cd "$(dirname "$0")/.."
APP="dist/lodestar.app"
[ -d "$APP" ] || { echo "✕ no $APP — run ./scripts/release.sh build first"; exit 1; }
VERSION=$(grep 'public static let version' Sources/LodestarCore/Version.swift | cut -d'"' -f2)
AGENT="$HOME/Library/LaunchAgents/com.vaccone.lodestar.plist"

# The installed app runs under launchd's KeepAlive; unload it or it
# comes straight back and takes the pid file from the build under test.
launchctl unload "$AGENT" 2>/dev/null || true
open -n "$APP"
echo "→ v$VERSION is running from $APP"
echo "  do: one click · one scroll · one keystroke · a lode gesture"
echo "  then press enter here (or ^C to abort and restore the installed app)"
restore() {
    launchctl load "$AGENT" 2>/dev/null || true
    echo "→ installed app restored (it takes the pid file back)"
}
trap restore EXIT
read -r
printf '%s' "$VERSION" > dist/.smoked
echo "✓ smoked v$VERSION — ship.sh will accept it"
