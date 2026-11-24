#!/bin/zsh
# One photograph of one surface from the debug harness, over the flat stage.
# usage: shoot.sh <out.png> <variant> <dark|light> <tint 0..1> [K=V ...]
# Extra K=V pairs reach the harness as environment: LODESTAR_GROUND=light|dark
# stages the opposing ground, PILL=typing picks the pill's state.
# The screen blacks out for about three seconds per shot.
out=${1:A}; variant=$2; appearance=$3; tint=$4; shift 4
cd "${0:A:h:h:h}"
env LODESTAR_STAGE=$appearance LODESTAR_ACCENT=orange "$@" \
  .build/debug/lodestar __strip-preview $variant -NSGlassTintAmount $tint >/dev/null 2>&1 &
pid=$!
screencapture -x -T 3 "$out"
kill $pid 2>/dev/null; wait $pid 2>/dev/null
echo "shot $out"
