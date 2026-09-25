#!/bin/bash
# The development build, run as your Lodestar: a Developer ID–signed app
# put in /Applications/lodestar.app, where the installed release lives and
# the login agent points, so it keeps the Accessibility grant (the grant
# follows the signature). The release app is set aside once, at
# dist/lodestar-release.app, and put back exactly on stop.
#
# The agent is unloaded while the bundle is swapped: its stub uninstalls
# Lodestar when it finds no binary, and a swap leaves none for a moment.
# The development build carries the version in Version.swift, so the
# updater leaves it alone until a newer release ships — and then replaces
# it with that release, which is the right ending anyway.
#
#   ./scripts/dev-build.sh start    build and run the development build
#   ./scripts/dev-build.sh stop     put the release app back
#   ./scripts/dev-build.sh status   which build is running
set -euo pipefail
cd "$(dirname "$0")/.."
AGENT="$HOME/Library/LaunchAgents/com.vaccone.lodestar.plist"
INSTALLED=/Applications/lodestar.app
BUILT=dist/lodestar.app
RELEASE=dist/lodestar-release.app
IDENTITY="Developer ID Application: Vaccone Software Company (2PZMN57974)"

running() { pgrep -fl "MacOS/lodestar$" | head -1; }
# The agent must point at /Applications; a start before any install, or
# an agent left pointing at the repo, is corrected the way the app would
# correct it on launch.
agent_target() { /usr/libexec/PlistBuddy -c "Print :ProgramArguments:4" "$AGENT" 2>/dev/null || true; }

case "${1:-status}" in
start)
    # Build first, while the installed app keeps running.
    swift build -c release
    LODESTAR_SIGN_IDENTITY="$IDENTITY" ./scripts/make-app.sh
    # Nothing is written into the bundle after it is signed: a changed seal
    # would cost the Accessibility grant.
    codesign --verify --strict "$BUILT"
    launchctl unload "$AGENT" 2>/dev/null || true
    if [ ! -d "$RELEASE" ] && [ -d "$INSTALLED" ]; then
        ditto "$INSTALLED" "$RELEASE"
        echo "release app set aside at $RELEASE ($(plutil -extract CFBundleShortVersionString raw "$RELEASE/Contents/Info.plist"))"
    fi
    rm -rf "$INSTALLED"
    ditto "$BUILT" "$INSTALLED"
    codesign --verify --strict "$INSTALLED" && echo "signature verified"
    if [ "$(agent_target)" != "$INSTALLED/Contents/MacOS/lodestar" ]; then
        # The app rewrites the agent to where it runs from and hands itself
        # to launchd; opening it once is the install.
        open "$INSTALLED"
    else
        launchctl load "$AGENT"
    fi
    sleep 4
    echo "running: $(running)"
    ;;
stop)
    [ -d "$RELEASE" ] || { echo "no release app set aside; nothing to restore"; exit 1; }
    launchctl unload "$AGENT" 2>/dev/null || true
    rm -rf "$INSTALLED"
    mv "$RELEASE" "$INSTALLED"
    launchctl load "$AGENT"
    sleep 4
    echo "release app back ($(plutil -extract CFBundleShortVersionString raw "$INSTALLED/Contents/Info.plist")): $(running)"
    ;;
status)
    if [ -d "$RELEASE" ]; then echo "development build installed (release set aside at $RELEASE)"; else echo "release build installed"; fi
    echo "agent runs: $(agent_target)"
    echo "running: $(running)"
    ;;
*)
    echo "usage: $0 start | stop | status"; exit 64 ;;
esac
