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
# Ask the toolchain where it put the product rather than assuming. Xcode 27
# moved the universal product from .build/apple/Products to
# .build/out/Products, and the old path, still holding the build from three
# days before, was packaged and shipped as v0.32.4 (2026-09-14).
if [ "${1:-}" = "--universal" ]; then
    swift build -c release --arch arm64 --arch x86_64
    BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/lodestar"
else
    swift build -c release
    BIN="$(swift build -c release --show-bin-path)/lodestar"
fi

APP=dist/lodestar.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp packaging/Info.plist "$APP/Contents/Info.plist"
mkdir -p "$APP/Contents/Resources"
cp packaging/lodestar.icns "$APP/Contents/Resources/lodestar.icns"
# The alert sound, so a person can pick Lodestar in Sound settings
# (it installs to ~/Library/Sounds; tools/sound/lodestar.py renders it).
cp packaging/Lodestar.aiff "$APP/Contents/Resources/Lodestar.aiff"
# The draft's two notes (app.sounds).
cp packaging/Listening.aiff packaging/Landed.aiff "$APP/Contents/Resources/"
# Stamp the bundle with the code's version — Version.swift is the truth.
VERSION=$(grep 'public static let version' Sources/LodestarCore/Version.swift | cut -d'"' -f2)
plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$VERSION" "$APP/Contents/Info.plist"
# The binary must be the code it is labelled as. A bare run is a CLI asking
# for help, and the first line names the version compiled in: ask it.
ANNOUNCED=$("$BIN" 2>/dev/null | sed -n 's/^Lodestar \([0-9.]*\):.*/\1/p' | head -1)
if [ "$ANNOUNCED" != "$VERSION" ]; then
    echo "✕ $BIN announces '${ANNOUNCED:-nothing}', not $VERSION: a stale product, refusing to package it" >&2
    exit 1
fi
# The binary must be the code it is labelled as. A bare run is a CLI asking
# for help, and the first line names the version compiled in: ask it.
ANNOUNCED=$("$BIN" 2>/dev/null | sed -n 's/^Lodestar \([0-9.]*\):.*/\1/p' | head -1)
if [ "$ANNOUNCED" != "$VERSION" ]; then
    echo "✕ $BIN announces '${ANNOUNCED:-nothing}', not $VERSION: a stale product, refusing to package it" >&2
    exit 1
fi
cp "$BIN" "$APP/Contents/MacOS/lodestar"

# LODESTAR_SIGN_IDENTITY overrides the choice. Worth reaching for when the
# app already installed was signed with a different certificate: the
# Accessibility grant is keyed to the signature, so testing a dev build over
# a Developer ID install means re-granting unless you match it.
IDENTITY="${LODESTAR_SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null \
    | awk -F'"' '/Apple Development/ {print $2; exit}')}"
if [ -n "${IDENTITY:-}" ]; then
    codesign --force --options runtime --sign "$IDENTITY" "$APP"
    echo "signed with: $IDENTITY"
else
    codesign --force --sign - "$APP"
    echo "signed ad-hoc (Accessibility grant will not survive rebuilds)"
fi
echo "built $APP"
