#!/bin/bash
# What the website reads from a release, written from the built app:
#   dist/lodestar-schema.json            the config schema (`lodestar schema`)
#   <site>/data/schema.json              the same, for the guide's option lists
# The download button's version is no longer written here: a ship is a
# preview build, and the site works out stable itself (/api/stable).
# The site checkout is $LODESTAR_SITE or ../lodestar-site; without one only
# the dist copy is written. Nothing is committed: the site is published by
# hand, after the release is. release.sh runs this after the self-test.
#   ./scripts/site-sync.sh [path/to/lodestar.app]
set -euo pipefail
cd "$(dirname "$0")/.."
APP="${1:-dist/lodestar.app}"
VERSION=$(plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist")
SCHEMA=dist/lodestar-schema.json

# The schema the shipped binary itself emits: the guide can then never
# describe an option the app does not have.
"$APP/Contents/MacOS/lodestar" schema > "$SCHEMA.tmp"
python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$SCHEMA.tmp"
mv "$SCHEMA.tmp" "$SCHEMA"
echo "→ schema: $SCHEMA"

SITE="${LODESTAR_SITE:-../lodestar-site}"
if [ ! -d "$SITE/data" ]; then
    echo "  no site checkout at $SITE; set LODESTAR_SITE to update it"
    exit 0
fi
cp "$SCHEMA" "$SITE/data/schema.json"
CHANGED=$(git -C "$SITE" status --short -- data/schema.json | wc -l | tr -d ' ')
echo "→ site: schema (v$VERSION) written to $SITE, $CHANGED file(s) changed, not committed"
