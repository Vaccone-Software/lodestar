#!/bin/bash
# Release pipeline: build → Developer ID sign → notarize → staple → zip,
# then the drag-pane DMG from the stapled app, notarized in its own right.
# One-time setup this script will walk you through:
#   1. A "Developer ID Application" certificate (Xcode → Settings →
#      Accounts → Manage Certificates → + → Developer ID Application).
#   2. Notary credentials in the keychain:
#      xcrun notarytool store-credentials lodestar-notary \
#        --apple-id <you> --team-id <TEAMID> --password <app-specific-pw>
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=$(grep 'public static let version' Sources/LodestarCore/Version.swift | cut -d'"' -f2)
APP=dist/lodestar.app
ARTIFACT="dist/lodestar-$VERSION.zip"
PROFILE=lodestar-notary

IDENTITY=$(security find-identity -v -p codesigning | grep "Developer ID Application" | head -1 | sed 's/.*"\(.*\)"/\1/' || true)
if [ -z "$IDENTITY" ]; then
    echo "✕ no 'Developer ID Application' certificate in the keychain."
    echo "  Xcode → Settings → Accounts → Manage Certificates → + → Developer ID Application"
    echo "  (requires the paid Apple Developer Program; Account Holder role creates it)"
    exit 1
fi

echo "→ testing"
swift test >/dev/null 2>&1 || { echo "✕ tests failed — no release from a red suite (run: swift test)"; exit 1; }

echo "→ building v$VERSION"
./scripts/make-app.sh --universal >/dev/null

echo "→ signing with: $IDENTITY"
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
codesign --verify --strict "$APP"

echo "→ submitting for notarization"
ditto -c -k --keepParent "$APP" "$ARTIFACT"
if ! xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
    echo "✕ notary credentials missing (keychain profile '$PROFILE')."
    echo "  xcrun notarytool store-credentials $PROFILE \\"
    echo "    --apple-id <your-apple-id> --team-id <TEAMID> --password <app-specific-password>"
    exit 1
fi
xcrun notarytool submit "$ARTIFACT" --keychain-profile "$PROFILE" --wait

echo "→ stapling"
xcrun stapler staple "$APP"
rm "$ARTIFACT"
ditto -c -k --keepParent "$APP" "$ARTIFACT"

DMG="dist/lodestar-$VERSION.dmg"
./scripts/make-dmg.sh
echo "→ signing the disk image"
codesign --force --timestamp --sign "$IDENTITY" "$DMG"
echo "→ notarizing the disk image"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$DMG"

echo "✓ notarized release artifacts:"
shasum -a 256 "$ARTIFACT" "$DMG"
