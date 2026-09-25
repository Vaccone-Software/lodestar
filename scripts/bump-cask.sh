#!/bin/bash
# Point the Homebrew cask at a release: version + zip sha256, and the
# requirements the build itself declares (its minimum macOS, and Apple
# silicon when it has no Intel slice), one commit to the tap. Shared by
# ship.sh (local) and release.yml (CI).
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
# What the build asks of a Mac, read from the build, never assumed.
mkdir -p "$STAGE/unpacked"
ditto -x -k "$ZIP" "$STAGE/unpacked"
APP_PLIST="$STAGE/unpacked/lodestar.app/Contents/Info.plist"
MINOS=$(plutil -extract LSMinimumSystemVersion raw "$APP_PLIST")
ARCHS=$(lipo -archs "$STAGE/unpacked/lodestar.app/Contents/MacOS/lodestar")
git -c credential.helper="$HELPER" clone -q "$TAP" "$STAGE/tap"
python3 - "$STAGE/tap/Casks/lodestar.rb" "$VERSION" "$SHA" "$MINOS" "$ARCHS" <<'PY'
import re, sys
path, version, sha, minos, archs = sys.argv[1:6]
names = {"13": "ventura", "14": "sonoma", "15": "sequoia", "26": "tahoe"}
major = minos.split(".")[0]
if major not in names:
    sys.exit(f"✕ no cask name for macOS {minos}")
s = open(path).read()
s = re.sub(r'version "[^"]*"', f'version "{version}"', s, count=1)
s = re.sub(r'sha256 "[^"]*"', f'sha256 "{sha}"', s, count=1)
s = re.sub(r'depends_on macos: :\w+', f'depends_on macos: :{names[major]}', s, count=1)
arm_only = "x86_64" not in archs.split()
line = re.search(r'^([ \t]*)depends_on macos:.*$', s, re.M)
if arm_only and "depends_on arch:" not in s and line:
    s = s[:line.end()] + f"\n{line.group(1)}depends_on arch: :arm64" + s[line.end():]
if not arm_only:
    s = re.sub(r'\n\s*depends_on arch: :arm64', '', s)
open(path, "w").write(s)
PY
# ${arr[@]+...} rather than a bare expansion: macOS bash 3.2 under set -u
# treats an empty array as unbound.
git -C "$STAGE/tap" ${IDENTITY[@]+"${IDENTITY[@]}"} commit -qam "Lodestar $VERSION"
git -C "$STAGE/tap" -c credential.helper="$HELPER" push -q origin main
echo "✓ cask → $VERSION ($SHA)"
