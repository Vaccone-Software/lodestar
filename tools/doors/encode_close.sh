#!/bin/zsh
# RECOVERED VERBATIM from transcript d6f88618-a0d2-4811-8ace-83f8ba3b2979.jsonl
# (2026-09-26 session scratchpad float/encode_close.sh, now deleted). Paths are relative to
# that scratchpad: float/ held scene3.py, r3/ (hero loops), r4/ (close-ups),
# site3/ (hero media), ../doorpages/ (door-page media). See STYLE.md.
# A door page's close-up loop: VP9 with alpha, HEVC with alpha in .mp4 for
# Safari, and its first frame as the poster.
cd "$(dirname "$0")/.."
for k in "$@"; do
  ffmpeg -y -loglevel error -framerate 24 -start_number 0 -i float/r4/$k/f%04d.png -c:v libvpx-vp9 -pix_fmt yuva420p -crf 32 -b:v 0 -row-mt 1 -deadline good -an doorpages/close-$k.webm
  ffmpeg -y -loglevel error -framerate 24 -start_number 0 -i float/r4/$k/f%04d.png -c:v hevc_videotoolbox -alpha_quality 0.8 -q:v 60 -tag:v hvc1 -movflags +faststart -an doorpages/close-$k.mp4
  cwebp -quiet -q 82 -alpha_q 90 float/r4/$k/f0000.png -o doorpages/close-$k.webp
done
ls -la doorpages/close-*
