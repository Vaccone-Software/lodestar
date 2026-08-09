#!/bin/bash
# Assemble dist/lodestar.app from the release build. Signs with your Apple
# Development identity when one exists (a stable signature keeps the
# Accessibility grant alive across rebuilds); ad-hoc otherwise.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release

APP=dist/lodestar.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp packaging/Info.plist "$APP/Contents/Info.plist"
mkdir -p "$APP/Contents/Resources"
cp packaging/lodestar.icns "$APP/Contents/Resources/lodestar.icns"
# Stamp the bundle with the code's version — Version.swift is the truth.
VERSION=$(grep 'public static let version' Sources/LodestarCore/Version.swift | cut -d'"' -f2)
plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$VERSION" "$APP/Contents/Info.plist"
cp .build/release/lodestar "$APP/Contents/MacOS/lodestar"

IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
    | awk -F'"' '/Apple Development/ {print $2; exit}')
if [ -n "${IDENTITY:-}" ]; then
    codesign --force --options runtime --sign "$IDENTITY" "$APP"
    echo "signed with: $IDENTITY"
else
    codesign --force --sign - "$APP"
    echo "signed ad-hoc (Accessibility grant will not survive rebuilds)"
fi
echo "built $APP"
