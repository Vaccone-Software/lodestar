#!/bin/bash
# Run the signed build before it ships: swap it in for the installed app,
# put a click, a scroll and a keystroke through its real taps, then put
# the installed app back. Writes dist/.smoked, which ship.sh requires.
#
#   ./scripts/smoke.sh auto     the gate ship.sh runs: launch the signed build,
#                               wait for its taps, post inert events through
#                               them (probe smoke), check it survived, restore
#   ./scripts/smoke.sh          by hand, in a terminal: launch, wait for enter, restore
#   ./scripts/smoke.sh start    launch the build and return (no terminal needed)
#   ./scripts/smoke.sh done     you did the acts: write the marker, restore
#   ./scripts/smoke.sh abort    restore without a marker
set -euo pipefail
cd "$(dirname "$0")/.."
APP="dist/lodestar.app"
VERSION=$(grep 'public static let version' Sources/LodestarCore/Version.swift | cut -d'"' -f2)
AGENT="$HOME/Library/LaunchAgents/com.vaccone.lodestar.plist"
MODE="${1:-interactive}"

# What a running build may rewrite to point at itself — the login agent
# and the CLI link — kept aside before it runs and put back after,
# whatever the build's own code does. Builds before 0.39.3 rewrote both.
STASH="dist/.smoke-stash"
LINKS="/opt/homebrew/bin/lodestar /usr/local/bin/lodestar"
stash() {
    mkdir -p "$STASH"
    [ -f "$AGENT" ] && cp "$AGENT" "$STASH/agent.plist"
    for link in $LINKS; do
        [ -L "$link" ] && readlink "$link" > "$STASH/$(echo "$link" | tr / _)"
    done
    return 0
}
unstash() {
    [ -f "$STASH/agent.plist" ] && cp "$STASH/agent.plist" "$AGENT"
    for link in $LINKS; do
        saved="$STASH/$(echo "$link" | tr / _)"
        [ -f "$saved" ] && ln -sfn "$(cat "$saved")" "$link"
    done
    # Opened once, the build is a registered copy of the app; unregistered,
    # a link or a login can only find the one in Applications.
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
        -u "$PWD/$APP" 2>/dev/null || true
    rm -rf "$STASH"
}

start() {
    [ -d "$APP" ] || { echo "✕ no $APP — run ./scripts/release.sh build first"; exit 1; }
    stash
    # The installed app runs under launchd's KeepAlive; unload it or it
    # comes straight back and takes the pid file from the build under test,
    # and let it finish going: two instances handing over are not the
    # build under test.
    launchctl bootout "gui/$(id -u)/com.vaccone.lodestar" 2>/dev/null || true
    for _ in $(seq 1 60); do
        pgrep -f "/Applications/lodestar.app/Contents/MacOS/lodestar" >/dev/null || break
        sleep 0.5
    done
    open -n "$APP"
    echo "→ v$VERSION is running from $APP"
    [ "$MODE" = auto ] || echo "  do: one click · one scroll · one keystroke · a lode gesture"
}

restore() {
    # In order: the build gone, the job unloaded, the files put back, the
    # job loaded from them. A build still shutting down makes the installed
    # app hand over and exit cleanly (the agent restarts only a crash), and
    # launchd keeps the job definition it last loaded — the build's own,
    # pointing at itself — until the job is booted out and loaded afresh.
    local domain="gui/$(id -u)"
    pkill -f "$PWD/$APP/Contents/MacOS/lodestar" 2>/dev/null || true
    for _ in $(seq 1 60); do
        pgrep -f "$PWD/$APP/Contents/MacOS/lodestar" >/dev/null || break
        sleep 0.5
    done
    launchctl bootout "$domain/com.vaccone.lodestar" 2>/dev/null || true
    unstash
    launchctl bootstrap "$domain" "$AGENT" 2>/dev/null || launchctl kickstart "$domain/com.vaccone.lodestar" 2>/dev/null || true
    echo "→ installed app restored (it takes the pid file back)"
}

mark() {
    printf '%s' "$VERSION" > dist/.smoked
    echo "✓ smoked v$VERSION — ship.sh will accept it"
}

# The acts a hand did, made without one. The build is launched as the
# hand would launch it, from its signed bundle under its own trust; the
# log says when its taps are up; probe smoke posts events no app acts on
# (a move in place, a scroll of nothing, mouse button 20, F20) and times
# each through Lodestar's taps to a listener after them; the process must
# still be the same one afterwards, with no stall, stopped tap or uncaught
# exception in its log. Posted events carry the poster's pid, so they are
# never counted as a hand's: the per-press health path is the one part of
# the old hand smoke this does not reach.
auto() {
    LOG="$HOME/.local/share/lodestar/lodestar.log"
    swift build --product probe >/dev/null
    PROBE="$(swift build --product probe --show-bin-path)/probe"
    BEFORE=$(wc -l < "$LOG" 2>/dev/null || echo 0)
    start
    trap restore EXIT
    local up="" pid=""
    for _ in $(seq 1 120); do
        pid=$(tail -n +"$((BEFORE + 1))" "$LOG" | sed -n "s/.*Lodestar $VERSION starting (pid \([0-9]*\)).*/\1/p" | tail -1)
        if [ -n "$pid" ] && tail -n +"$((BEFORE + 1))" "$LOG" | grep -q "hotkeys: tap active"; then up=1; break; fi
        sleep 0.5
    done
    [ -n "$up" ] || { echo "✕ v$VERSION never said its taps were up"; exit 1; }
    echo "→ v$VERSION up (pid $pid); posting through its taps"
    "$PROBE" smoke --seconds 6 || { echo "✕ the taps dropped or held events"; exit 1; }
    sleep 1
    kill -0 "$pid" 2>/dev/null || { echo "✕ v$VERSION died during the smoke"; exit 1; }
    if tail -n +"$((BEFORE + 1))" "$LOG" | grep -E "main thread stalled|tap had stopped|uncaught-exception|during=run"; then
        echo "✕ v$VERSION's log above says something went wrong"; exit 1
    fi
    mark
}

case "$MODE" in
    auto) auto;;
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
    *) echo "usage: smoke.sh [auto|start|done|abort]"; exit 64;;
esac
