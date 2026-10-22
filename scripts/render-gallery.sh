#!/bin/bash
# Every surface, drawn offscreen to a PNG (2x) in day and night: the
# launcher, the bars, Settings, Keep, the pill, the chips, the cards, the
# controls and the keys, and the foundations (the palette's colours with
# their contrast, the theme's type). No app launch and no screen recording:
# the real views are laid out in windows that are never ordered in, and
# AppKit draws them (layers, keys and shadows included) into bitmaps. The
# glass material composites out of process and does not draw offscreen; see
# the note on the index page.
#
#   scripts/render-gallery.sh [outdir]       default .build/gallery
#   LODESTAR_RENDER_ONLY=launcher scripts/render-gallery.sh
#                                            only the pictures whose name has that
#
# Files are <surface>-<state>-<look>.png (look: day, night);
# gallery/index.html is the page to review them on.
# Pictures already in outdir stay; the ones this makes are overwritten.
set -uo pipefail
cd "$(dirname "$0")/.."

OUT=${1:-.build/gallery}
mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)

if ! build=$(swift build --build-tests 2>&1); then
    echo "$build" | grep -E "error" | head -20
    echo "✕ the tests do not build"
    exit 1
fi
BIN=$(swift build --show-bin-path)
BUNDLE="$BIN/LodestarAppTests.xctest"
[ -d "$BUNDLE" ] || BUNDLE=$(ls -d "$BIN"/*PackageTests.xctest 2>/dev/null | head -1)

LODESTAR_RENDER="$OUT" xcrun xctest -XCTest LodestarAppTests.RenderGalleryTests "$BUNDLE" 2>&1 \
    | grep -E "gallery:|error|Executed|✕|not rendered" | grep -v "^Test Suite"
count=$(ls "$OUT"/*.png 2>/dev/null | wc -l | tr -d ' ')
echo "→ $count pictures in $OUT; open $OUT/gallery/index.html"
