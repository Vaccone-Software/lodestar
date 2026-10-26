#!/bin/zsh
# Every door and place picture as a cameo, written into packaging/: a relief and
# its outline from cameo.py, cut into night (<name>.png) and day (<name>-sand.png)
# by cameo.swift. About thirty seconds a picture. See STYLE.md, "Cameo".
#
#   FONT_DIR=<fonts> tools/doors/render_cameo.sh [picture ...]   default: all ten
set -euo pipefail
cd "$(dirname "$0")"
: "${FONT_DIR:?FONT_DIR must hold Inter-Medium.ttf and Newsreader_ital_wght_1_400.ttf (STYLE.md, Fonts)}"
BLENDER=/Applications/Blender.app/Contents/MacOS/Blender
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
pictures=("$@")
(( $# )) || pictures=(door-write door-switch door-keep door-speak place-general place-operate place-web place-meetings place-keys place-observations)
for picture in $pictures; do
    folder=../../packaging/places
    [[ $picture == door-* ]] && folder=../../packaging/doors
    "$BLENDER" -b --python-exit-code 1 -P cameo.py -- "$picture" "$WORK/$picture.png" > "$WORK/$picture.log" 2>&1 \
        || { tail -20 "$WORK/$picture.log"; exit 1; }
    MASK=1 "$BLENDER" -b --python-exit-code 1 -P cameo.py -- "$picture" "$WORK/$picture-mask.png" > "$WORK/$picture-mask.log" 2>&1 \
        || { tail -20 "$WORK/$picture-mask.log"; exit 1; }
    swift cameo.swift "$WORK/$picture.png" "$WORK/$picture-mask.png" "$folder/$picture.png" "$folder/$picture-sand.png"
    echo "✓ $picture"
done
