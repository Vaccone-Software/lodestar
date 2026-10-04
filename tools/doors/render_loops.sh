#!/bin/zsh
# RECOVERED VERBATIM from transcript d6f88618-a0d2-4811-8ace-83f8ba3b2979.jsonl
# (2026-09-26 session scratchpad float/render_loops.sh, now deleted). Paths are relative to
# that scratchpad: float/ held scene3.py, r3/ (hero loops), r4/ (close-ups),
# site3/ (hero media), ../doorpages/ (door-page media). See STYLE.md.
cd "$(dirname "$0")"
rm -rf r3
for k in markroot write move keep speak; do
  /Applications/Blender.app/Contents/MacOS/Blender -b -P scene3.py -- $k $PWD/r3 2000 64 > r3-$k.log 2>&1
  echo "$k done $(ls r3/$k | wc -l)"
done
