#!/bin/bash
# The development build, run as your Lodestar: a Developer ID–signed app
# put in /Applications/lodestar.app, where the installed release lives and
# the login agent points, so it keeps the Accessibility grant (the grant
# follows the signature). The release app is set aside at
# dist/lodestar-release.app, and put back on stop.
#
# The agent is unloaded while the bundle is swapped: its stub uninstalls
# Lodestar when it finds no binary, and a swap leaves none for a moment.
# The development build carries the version in Version.swift, so the
# updater leaves it alone until a newer release ships — and then replaces
# it with that release, which is the right ending anyway.
#
# Stop never puts back a release older than the development build's work.
# That build may have written what an older one cannot read (0.52's cards
# of files, which 0.51 sets aside with the whole history), so stop puts
# back the copy set aside only when it holds the development build's
# commit, or failing that carries a newer version. Otherwise it installs
# the newest published release that does, checked for Lodestar's
# signature and notarization, and failing both it refuses.
#
#   ./scripts/dev-build.sh start          build and run the development build
#   ./scripts/dev-build.sh stop           put a release back
#   ./scripts/dev-build.sh stop --older   put back the copy set aside, older or not
#   ./scripts/dev-build.sh status         which build is running
set -euo pipefail
cd "$(dirname "$0")/.."
# The paths and services are the real ones; the tests point them elsewhere.
AGENT="${DEV_BUILD_AGENT:-$HOME/Library/LaunchAgents/com.vaccone.lodestar.plist}"
INSTALLED="${DEV_BUILD_INSTALLED:-/Applications/lodestar.app}"
BUILT=dist/lodestar.app
RELEASE="${DEV_BUILD_RELEASE:-dist/lodestar-release.app}"
RELEASES_API="${DEV_BUILD_RELEASES_API:-https://api.github.com/repos/Vaccone-Software/lodestar/releases?per_page=10}"
DOWNLOADS="${DEV_BUILD_DOWNLOADS:-https://github.com/Vaccone-Software/lodestar/releases/download}"
REPO="${DEV_BUILD_REPO:-.}"
SETTLE="${DEV_BUILD_SETTLE:-4}"
TEAM=2PZMN57974
IDENTITY="Developer ID Application: Vaccone Software Company ($TEAM)"

running() { pgrep -fl "MacOS/lodestar$" | head -1 || true; }
# The agent must point at /Applications; a start before any install, or
# an agent left pointing at the repo, is corrected the way the app would
# correct it on launch.
agent_target() { /usr/libexec/PlistBuddy -c "Print :ProgramArguments:4" "$AGENT" 2>/dev/null || true; }
version_of() { plutil -extract CFBundleShortVersionString raw "$1/Contents/Info.plist"; }
# make-app.sh stamps a development build, and its commit when the tree
# it was built from was clean.
is_development() { [ "$(plutil -extract LodestarDevelopment raw "$1/Contents/Info.plist" 2>/dev/null)" = true ]; }
commit_of() { plutil -extract LodestarCommit raw "$1/Contents/Info.plist" 2>/dev/null || true; }
newer() { [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1)" = "$1" ]; }

# Whether release $1 (built from commit $2, when known) holds everything
# the development build does: its commit has the build's in its history,
# or, when either commit is unknown here, its version is newer.
holds_development() {
    local version=$1 commit=${2:-}
    if [ -n "$DEV_COMMIT" ] && [[ "$commit" =~ ^[0-9a-f]{40}$ ]] \
        && git -C "$REPO" cat-file -e "$commit^{commit}" 2>/dev/null \
        && git -C "$REPO" cat-file -e "$DEV_COMMIT^{commit}" 2>/dev/null; then
        git -C "$REPO" merge-base --is-ancestor "$DEV_COMMIT" "$commit"
    else
        newer "$version" "$DEV_VERSION"
    fi
}

# The published releases, newest version first, as "version commit".
# GitHub lists no drafts to a caller without a token; a draft is skipped
# all the same.
published_releases() {
    local list i tag
    list=$(mktemp)
    if ! curl -fsSL --max-time 20 -o "$list" "$RELEASES_API" 2>/dev/null; then rm -f "$list"; return 1; fi
    for ((i = 0; ; i++)); do
        tag=$(plutil -extract "$i.tag_name" raw -o - "$list" 2>/dev/null) || break
        [ "$(plutil -extract "$i.draft" raw -o - "$list" 2>/dev/null)" = false ] || continue
        echo "${tag#v} $(plutil -extract "$i.target_commitish" raw -o - "$list" 2>/dev/null || true)"
    done | sort -rV
    rm -f "$list"
}

# Swap $1 in as the installed app, the agent unloaded around it.
install_app() {
    launchctl unload "$AGENT" 2>/dev/null || true
    rm -rf "$INSTALLED"
    if [ "${2:-}" = move ]; then mv "$1" "$INSTALLED"; else ditto "$1" "$INSTALLED"; fi
    launchctl load "$AGENT"
    sleep "$SETTLE"
}

# Download release $1 and install it, when it is Lodestar's own: the
# version it says, no development stamp, a valid signature by this team,
# and Gatekeeper's acceptance (it is notarized).
install_published() {
    local version=$1 work app
    work=$(mktemp -d)
    WORK=$work
    trap 'rm -rf "$WORK"' EXIT
    echo "→ downloading release $version"
    if ! curl -fsSL --retry 2 --max-time 600 -o "$work/lodestar.zip" "$DOWNLOADS/v$version/lodestar-$version.zip"; then
        echo "✕ could not download release $version"; return 1
    fi
    ditto -x -k "$work/lodestar.zip" "$work/unpacked"
    app="$work/unpacked/lodestar.app"
    [ -d "$app" ] || { echo "✕ release $version's zip holds no lodestar.app"; return 1; }
    [ "$(version_of "$app")" = "$version" ] || { echo "✕ release $version's app says it is $(version_of "$app")"; return 1; }
    ! is_development "$app" || { echo "✕ release $version's app is a development build"; return 1; }
    codesign --verify --strict "$app" 2>/dev/null || { echo "✕ release $version's signature does not verify"; return 1; }
    codesign -dv "$app" 2>&1 | grep -qx "TeamIdentifier=$TEAM" || { echo "✕ release $version is not signed by Lodestar's team"; return 1; }
    spctl --assess --type execute "$app" 2>/dev/null || { echo "✕ Gatekeeper refuses release $version"; return 1; }
    install_app "$app"
}

case "${1:-status}" in
start)
    # Build first, while the installed app keeps running.
    swift build -c release
    LODESTAR_DEVELOPMENT=1 LODESTAR_SIGN_IDENTITY="$IDENTITY" ./scripts/make-app.sh
    # Nothing is written into the bundle after it is signed: a changed seal
    # would cost the Accessibility grant.
    codesign --verify --strict "$BUILT"
    launchctl unload "$AGENT" 2>/dev/null || true
    # A release in place is the one to set aside, newer than any copy kept
    # before it: the updater may have put it over the last development build.
    if [ -d "$INSTALLED" ] && ! is_development "$INSTALLED"; then
        rm -rf "$RELEASE"
        ditto "$INSTALLED" "$RELEASE"
        echo "release app set aside at $RELEASE ($(version_of "$RELEASE"))"
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
    OLDER=
    [ "${2:-}" = --older ] && OLDER=1
    if [ -d "$INSTALLED" ] && ! is_development "$INSTALLED"; then
        # The updater has put a release over the development build already.
        echo "release $(version_of "$INSTALLED") is installed already"
        if [ -d "$RELEASE" ] && ! newer "$(version_of "$RELEASE")" "$(version_of "$INSTALLED")"; then
            echo "removed the copy set aside ($(version_of "$RELEASE")): the release in place supersedes it"
            rm -rf "$RELEASE"
        fi
        exit 0
    fi
    [ -d "$INSTALLED" ] || { echo "✕ no Lodestar at $INSTALLED"; exit 1; }
    DEV_VERSION=$(version_of "$INSTALLED")
    DEV_COMMIT=$(commit_of "$INSTALLED")
    SET_ASIDE=
    [ -d "$RELEASE" ] && SET_ASIDE=$(version_of "$RELEASE")

    RELEASES=$(published_releases) || RELEASES=
    [ -n "$RELEASES" ] || echo "(GitHub's releases could not be read; judging by versions alone)"
    commit_for() { awk -v v="$1" '$1 == v { print $2; exit }' <<< "$RELEASES"; }

    if [ -n "$SET_ASIDE" ] && { [ -n "$OLDER" ] || holds_development "$SET_ASIDE" "$(commit_for "$SET_ASIDE")"; }; then
        install_app "$RELEASE" move
        echo "release app back ($(version_of "$INSTALLED")): $(running)"
        exit 0
    fi
    read -r NEWEST NEWEST_COMMIT <<< "$(head -1 <<< "$RELEASES")" || true
    if [ -n "${NEWEST:-}" ] && holds_development "$NEWEST" "${NEWEST_COMMIT:-}"; then
        install_published "$NEWEST"
        echo "release $NEWEST installed: $(running)"
        if [ -n "$SET_ASIDE" ]; then
            rm -rf "$RELEASE"
            echo "removed the copy set aside ($SET_ASIDE): it is older than the development build"
        fi
        exit 0
    fi
    echo "✕ no release holds this development build's work ($DEV_VERSION${DEV_COMMIT:+, ${DEV_COMMIT:0:7}})."
    echo "  An older release may not read what it wrote: 0.51 sets a history with cards of files aside."
    echo "  Ship it, wait for the updater, or put back the copy set aside${SET_ASIDE:+ ($SET_ASIDE)} with: $0 stop --older"
    exit 1
    ;;
status)
    if [ -d "$INSTALLED" ] && is_development "$INSTALLED"; then
        echo "development build installed ($(version_of "$INSTALLED"))"
        [ -d "$RELEASE" ] && echo "release set aside at $RELEASE ($(version_of "$RELEASE"))"
    elif [ -d "$INSTALLED" ]; then
        echo "release build installed ($(version_of "$INSTALLED"))"
        [ -d "$RELEASE" ] && echo "a copy is also set aside at $RELEASE ($(version_of "$RELEASE"))"
    else
        echo "no Lodestar at $INSTALLED"
    fi
    echo "agent runs: $(agent_target)"
    echo "running: $(running)"
    ;;
*)
    echo "usage: $0 start | stop [--older] | status"; exit 64 ;;
esac
