#!/bin/zsh
# RECOVERED VERBATIM from transcript d6f88618-a0d2-4811-8ace-83f8ba3b2979.jsonl
# (2026-09-26 session scratchpad float/render_close.sh, now deleted). Paths are relative to
# that scratchpad: float/ held scene3.py, r3/ (hero loops), r4/ (close-ups),
# site3/ (hero media), ../doorpages/ (door-page media). See STYLE.md.
# The door pages' portraits: each door alone, framed close, looping.
cd "$(dirname "$0")"
# Wait for the hero's keep loop to finish first.
while [ "$(ls r3/keep 2>/dev/null | wc -l | tr -d ' ')" -lt 192 ]; do sleep 20; done
rm -rf r4
for k in write keep speak move; do
  CLOSE=1 CW=1200 CH=900 /Applications/Blender.app/Contents/MacOS/Blender -b -P scene3.py -- $k $PWD/r4 1200 48 > r4-$k.log 2>&1
  echo "$k $(ls r4/$k | wc -l)"
done
