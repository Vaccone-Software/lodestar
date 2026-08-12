#!/bin/bash
# Assemble dist/lodestar.app from the release build. Signs with your Apple
# Development identity when one exists (a stable signature keeps the
# Accessibility grant alive across rebuilds); ad-hoc otherwise.
#
# --universal builds arm64 + x86_64 (public artifacts); default stays
# native so dev installs rebuild fast.
set -euo pipefail
cd "$(dirname "$0")/.."

BIN=.build/release/lodestar
if [ "${1:-}" = "--universal" ]; then
    swift build -c release --arch arm64 --arch x86_64
    BIN=.build/apple/Products/Release/lodestar
else
    swift build -c release
fi

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
cp "$BIN" "$APP/Contents/MacOS/lodestar"

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
