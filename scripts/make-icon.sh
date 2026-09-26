#!/bin/bash
# Renders Lodestar's mark from Sources/LodestarCore/Mark.swift: the app icon
# (.icns and every size of its iconset), a 1024 preview, the website's
# favicon (icon.svg), the bare mark (mark.svg), and the faces with their
# fills for the site's logo and touch icon (mark.json).
#
#   ./scripts/make-icon.sh                     International Orange, the shipped color
#   ./scripts/make-icon.sh --accent '#0A84FF'  any color, by hex
#   ./scripts/make-icon.sh --preset green      a named color (Mark.presets)
#   ./scripts/make-icon.sh --all               every preset, each in its own folder
#   ./scripts/make-icon.sh --install           the shipped color, then copied into
#                                              packaging/ and the site checkout
#
# Output goes to .build/mark/<color>/. Nothing is copied anywhere unless
# --install is given; the site checkout is $LODESTAR_SITE or ../lodestar-site.
set -euo pipefail
cd "$(dirname "$0")/.."
INSTALL=0
ARGS=()
for arg in "$@"; do
    if [ "$arg" = "--install" ]; then INSTALL=1; else ARGS+=("$arg"); fi
done
./scripts/swift-with-mark.sh scripts/make-icon.swift ${ARGS[@]+"${ARGS[@]}"}
for dir in .build/mark/*/; do
    [ -d "$dir/lodestar.iconset" ] && iconutil -c icns "$dir/lodestar.iconset" -o "$dir/lodestar.icns"
done
if [ "$INSTALL" = 1 ]; then
    OUT=.build/mark/international-orange
    [ -f "$OUT/lodestar.icns" ] || { echo "✕ --install ships International Orange; run without --accent/--preset"; exit 1; }
    cp "$OUT/lodestar.icns" packaging/lodestar.icns
    echo "→ packaging/lodestar.icns"
    SITE="${LODESTAR_SITE:-../lodestar-site}"
    if [ -d "$SITE/app" ]; then
        cp "$OUT/icon.svg" "$SITE/app/icon.svg"
        cp "$OUT/mark.json" "$SITE/data/mark.json"
        echo "→ $SITE/app/icon.svg, $SITE/data/mark.json (not committed)"
    else
        echo "  no site checkout at $SITE; set LODESTAR_SITE to update it"
    fi
fi
