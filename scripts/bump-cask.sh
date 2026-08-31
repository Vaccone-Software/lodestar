#!/bin/bash
# Point the Homebrew cask at a release: version + zip sha256, one commit
# to the tap. Shared by ship.sh (local) and release.yml (CI).
#   ./scripts/bump-cask.sh <version> <zip-path>
# Credentials: gh's, unless TAP_TOKEN is set (CI), in which case that
# token authenticates the clone and the push.
set -euo pipefail
VERSION="${1:?usage: bump-cask.sh <version> <zip>}"
ZIP="${2:?usage: bump-cask.sh <version> <zip>}"
[ -f "$ZIP" ] || { echo "✕ $ZIP missing"; exit 1; }

TAP="https://github.com/Vaccone-Software/homebrew-tap.git"
SHA=$(shasum -a 256 "$ZIP" | cut -d' ' -f1)
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT

if [ -n "${TAP_TOKEN:-}" ]; then
    # Single-quoted on purpose: the helper reads TAP_TOKEN from its own
    # environment when git runs it, so the token is never in an argv.
    export TAP_TOKEN
    HELPER='!f() { echo username=x-access-token; echo "password=$TAP_TOKEN"; }; f'
    IDENTITY=(-c user.name=lodestar-release -c user.email=release@lodestar.invalid)
else
    HELPER='!gh auth git-credential'
    IDENTITY=()
fi
git -c credential.helper="$HELPER" clone -q "$TAP" "$STAGE"
python3 - "$STAGE/Casks/lodestar.rb" "$VERSION" "$SHA" <<'PY'
import re, sys
path, version, sha = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(path).read()
s = re.sub(r'version "[^"]*"', f'version "{version}"', s, count=1)
s = re.sub(r'sha256 "[^"]*"', f'sha256 "{sha}"', s, count=1)
open(path, "w").write(s)
PY
git -C "$STAGE" "${IDENTITY[@]}" commit -qam "Lodestar $VERSION"
git -C "$STAGE" -c credential.helper="$HELPER" push -q origin main
echo "✓ cask → $VERSION ($SHA)"
