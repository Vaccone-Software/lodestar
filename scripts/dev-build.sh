#!/bin/bash
# The development build, run as your Lodestar: a Developer ID–signed app
# at dist/lodestar.app, where the login agent already points, so it keeps
# the Accessibility grant (the grant follows the signature). The release
# app is set aside once and put back exactly on stop.
#
# The agent is unloaded while the bundle is rebuilt: its stub uninstalls
# Lodestar when it finds no binary, and a rebuild leaves none for a moment.
#
#   ./scripts/dev-build.sh start    build and run the development build
#   ./scripts/dev-build.sh stop     put the release app back
#   ./scripts/dev-build.sh status   which build is running
set -euo pipefail
cd "$(dirname "$0")/.."
AGENT="$HOME/Library/LaunchAgents/com.vaccone.lodestar.plist"
APP=dist/lodestar.app
RELEASE=dist/lodestar-release.app
IDENTITY="Developer ID Application: Vaccone Software Company (2PZMN57974)"

running() { pgrep -fl "$PWD/$APP/Contents/MacOS/lodestar" | head -1; }

case "${1:-status}" in
start)
    # Build first, while the current app keeps running.
    swift build -c release
    launchctl unload "$AGENT" 2>/dev/null || true
    if [ ! -d "$RELEASE" ] && [ -d "$APP" ]; then
        mv "$APP" "$RELEASE"
        echo "release app set aside at $RELEASE"
    fi
    LODESTAR_SIGN_IDENTITY="$IDENTITY" ./scripts/make-app.sh
    # Nothing is written into the bundle after it is signed: a changed seal
    # would cost the Accessibility grant.
    codesign --verify --strict "$APP" && echo "signature verified"
    launchctl load "$AGENT"
    sleep 3
    echo "running: $(running)"
    ;;
stop)
    [ -d "$RELEASE" ] || { echo "no release app set aside; nothing to restore"; exit 1; }
    launchctl unload "$AGENT" 2>/dev/null || true
    rm -rf "$APP"
    mv "$RELEASE" "$APP"
    launchctl load "$AGENT"
    sleep 3
    echo "release app back: $(running)"
    ;;
status)
    if [ -d "$RELEASE" ]; then echo "development build installed (release set aside)"; else echo "release build installed"; fi
    echo "running: $(running)"
    ;;
*)
    echo "usage: $0 start | stop | status"; exit 64 ;;
esac
