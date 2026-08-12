#!/bin/bash
# Assemble dist/lodestar-<version>.dmg from dist/lodestar.app — the drag
# pane a download button implies: app on the left, Applications on the
# right, the transfer arc drawn between them. Renders the background from
# source, lays out the Finder window, compresses. Signing, notarization,
# and stapling stay in release.sh with the zip.
#
# The Finder layout step needs Automation consent for the terminal that
# runs it (System Settings prompts once).
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=$(grep 'public static let version' Sources/LodestarCore/Version.swift | cut -d'"' -f2)
APP=dist/lodestar.app
DMG="dist/lodestar-$VERSION.dmg"
VOLUME=Lodestar

[ -d "$APP" ] || { echo "✕ $APP missing — run scripts/make-app.sh first"; exit 1; }
if [ -d "/Volumes/$VOLUME" ]; then
    echo "✕ a '$VOLUME' volume is already mounted — eject it first"
    exit 1
fi

STAGE=$(mktemp -d)
DEVICE=""
cleanup() {
    [ -n "$DEVICE" ] && hdiutil detach "$DEVICE" -quiet 2>/dev/null
    rm -rf "$STAGE"
}
trap cleanup EXIT

echo "→ staging"
mkdir "$STAGE/root"
cp -R "$APP" "$STAGE/root/lodestar.app"
ln -s /Applications "$STAGE/root/Applications"
mkdir "$STAGE/root/.background"
swift scripts/make-dmg-background.swift "$STAGE/root/.background" "$VERSION" >/dev/null
tiffutil -cathidpicheck "$STAGE/root/.background/background.png" \
    "$STAGE/root/.background/background@2x.png" \
    -out "$STAGE/root/.background/background.tiff" >/dev/null 2>&1
rm "$STAGE/root/.background/background.png" "$STAGE/root/.background/background@2x.png"
cp packaging/lodestar.icns "$STAGE/root/.VolumeIcon.icns"

echo "→ building image"
hdiutil create -srcfolder "$STAGE/root" -volname "$VOLUME" -fs HFS+ \
    -format UDRW -size 48m "$STAGE/rw.dmg" -quiet
ATTACH=$(hdiutil attach -readwrite -noverify -noautoopen "$STAGE/rw.dmg")
DEVICE=$(echo "$ATTACH" | awk '/\/Volumes\//{print $1}')
MOUNT=$(echo "$ATTACH" | grep -o '/Volumes/.*')

# The custom-icon Finder bit; SetFile when Xcode provides it, raw
# FinderInfo otherwise.
if xcrun -f SetFile >/dev/null 2>&1; then
    xcrun SetFile -a C "$MOUNT"
else
    xattr -wx com.apple.FinderInfo \
        "0000000000000000040000000000000000000000000000000000000000000000" "$MOUNT"
fi

echo "→ laying out the window"
# Finder places an icon's center 28pt below the requested y; the art's
# icon row sits at 200, so ask for 172. Hidden files park below the fold
# for anyone browsing with ⌘⇧. on. Bounds are re-set after the reopen —
# the final close persists that window's frame, not the first one's.
osascript <<OSA
tell application "Finder"
    tell disk "$VOLUME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {400, 120, 1060, 552}
        set options to the icon view options of container window
        set arrangement of options to not arranged
        set icon size of options to 96
        set text size of options to 12
        set background picture of options to file ".background:background.tiff"
        set position of item "lodestar.app" of container window to {165, 172}
        try
            set extension hidden of item "lodestar.app" to true
        end try
        set position of item "Applications" of container window to {495, 172}
        repeat with dotName in {".background", ".fseventsd", ".VolumeIcon.icns", ".Trashes"}
            try
                set position of item dotName of container window to {165, 700}
            end try
        end repeat
        update without registering applications
        delay 1
        close
        open
        set the bounds of container window to {400, 120, 1060, 552}
        update without registering applications
        delay 1
        close
    end tell
end tell
OSA
sync

hdiutil detach "$DEVICE" -quiet
DEVICE=""
rm -f "$DMG"
hdiutil convert "$STAGE/rw.dmg" -format UDZO -imagekey zlib-level=9 -o "$DMG" -quiet
echo "built $DMG"
