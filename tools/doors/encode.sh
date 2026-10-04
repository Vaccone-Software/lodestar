#!/bin/zsh
# RECOVERED VERBATIM from transcript d6f88618-a0d2-4811-8ace-83f8ba3b2979.jsonl
# (2026-09-26 session scratchpad float/encode.sh, now deleted). Paths are relative to
# that scratchpad: float/ held scene3.py, r3/ (hero loops), r4/ (close-ups),
# site3/ (hero media), ../doorpages/ (door-page media). See STYLE.md.
# Each loop as VP9 with alpha (Chrome, Firefox), HEVC with alpha (Safari),
# and its first frame as a WebP poster; then the page with the crops.
cd "$(dirname "$0")"
mkdir -p site3
for k in markroot write move keep speak; do
  ffmpeg -y -loglevel error -framerate 24 -start_number 0 -i r3/$k/f%04d.png -c:v libvpx-vp9 -pix_fmt yuva420p -crf 31 -b:v 0 -row-mt 1 -deadline good -an site3/$k.webm
  ffmpeg -y -loglevel error -framerate 24 -start_number 0 -i r3/$k/f%04d.png -c:v hevc_videotoolbox -alpha_quality 0.8 -q:v 62 -tag:v hvc1 -an site3/$k.mov
  cwebp -quiet -q 82 -alpha_q 90 r3/$k/f0000.png -o site3/$k.webp
done
python3 - <<'PY'
import json, pathlib, struct
d = pathlib.Path("r3"); crops = {}
for k in ["markroot", "write", "move", "keep", "speak"]:
    c = json.load(open(d / f"{k}.json"))
    png = open(d / k / "f0000.png", "rb").read(32); w, h = struct.unpack(">II", png[16:24])
    crops[k] = {**{x: round(c[x], 5) for x in ("x0", "x1", "y0", "y1")}, "w": w, "h": h}
s = open("site3/template.html").read()
open("site3/hero.html", "w").write(s.replace("{{CROPS}}", json.dumps(crops)))
PY
ls -la site3
