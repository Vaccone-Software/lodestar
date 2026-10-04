# Door pictures: style guide and recipe

How Lodestar's four door pictures were made, taken from the script that made
them. That script is `scene3.py` in this folder, recovered from session
d6f88618 (2026-09-26). The outputs:

- `packaging/doors/door-{write,switch,keep,speak}.png`: 360×270 RGBA, the
  first-launch door pictures
- `lodestar-site/public/media/doors/{write,switch,keep,speak}.{webm,mp4,webp}`:
  1200×900 close-up loops for the door pages
- `lodestar-site/public/media/hero/{write,switch,keep,speak,mark}.{webm,mp4,webp}`:
  the homepage loops, each cropped to its own motion

"Move" was renamed "Switch" late in the session. The script still calls the
door `move`. `switch.*` and `door-switch.png` are renders of `move`.

A recovered test render (frame 40 of Write and of Keep, CLOSE mode) matches the
shipped PNGs. Keep's `FRAMED` line also reproduces the transcript's numbers
exactly (lens 177.8656).

## The look in one paragraph

Matte, pale, warm clay objects with soft bevels float in empty space against a
transparent background. Each one is a simplified piece of the app: a note, a
stack of windows, clipboard cards, the draft panel. International Orange
(#FF4F00) appears only on the one detail that matters in each door. A big
soft key light from the upper left, a warm rim from behind and a cool fill from
low right give the clay form. A faint orange point light at the mark (the
star) puts a hint of its glow on things. There is no floor, no contact shadow
and no environment map. This is "Superhot turned dark, done in Blender."

## Render settings

| Setting             | Value                                                                                                                                                                                                                             |
| ------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| App                 | Blender 5.0.1, `/Applications/Blender.app`, headless (`-b -P`)                                                                                                                                                                    |
| Engine              | Cycles on GPU (`compute_device_type = "METAL"`, every device on)                                                                                                                                                                  |
| Samples             | 64 for homepage loops (width 2000), 48 for close-ups (1200×900). The door PNGs come from the 48-sample close-ups. (Defaults when no argument is given: 128.)                                                                      |
| Denoise             | `scene.cycles.use_denoising = True`, Blender's default denoiser                                                                                                                                                                   |
| Film                | `film_transparent = True` (set in the rendering section, which overrides the `False` near the top)                                                                                                                                |
| Colour              | `view_transform = "Standard"`, `look = "None"`. Not AgX, not Filmic. Every hex value goes through `lin()` (exact sRGB to linear) before use.                                                                                      |
| Output              | PNG RGBA, frames `f0000.png …`                                                                                                                                                                                                    |
| Frame rate          | 24 fps                                                                                                                                                                                                                            |
| Homepage resolution | width × width·10/16 (2000×1250), then cropped with `use_border` + `use_crop_to_border` to the door's motion box, padded by 0.012 in x and 0.0192 in y, with even pixel sizes for the encoders. The crop is written to `<k>.json`. |
| Close-up resolution | `CW`×`CH` = 1200×900 (4:3), no crop                                                                                                                                                                                               |

## World

A Light Path mix:

- Camera rays see `#121215` at strength 1. Film is transparent, so this never
  shows.
- Every other ray sees `#2A2830` at strength **0.35**, a dim, slightly violet
  ambient fill.

No HDRI.

## Lights

All lights are aimed with `to_track_quat("-Z","Y")`. Power is in watts.

| Light | Type  | Position                                   | Aimed at    | Power  | Size          | Colour  |
| ----- | ----- | ------------------------------------------ | ----------- | ------ | ------------- | ------- |
| key   | Area  | (-6, -7, 7)                                | (0, 0, 0.5) | 2400   | 6             | #FFF6EE |
| rim   | Area  | (5, 7, 5)                                  | (0, 0, 0.5) | 1200   | 5             | #FFE2CC |
| fill  | Area  | (7, -6, -3)                                | (0, 0, 0.5) | 450    | 8             | #DFE6FF |
| core  | Point | (0, -0.6, 1.25), just in front of the mark | none        | **90** | soft size 0.6 | #FF5A14 |

`core` is "the hint of the mark's orange light". It was 260 W at first.
Anything stronger "turned the pale clay pink", so it was cut to 90. A "Lit by
the mark" variant (900 W core, key ×0.35) was tried and not chosen: it read as
a sun.

## Camera

- Perspective camera at **(0, -17, 1.6)**, aimed at (0, 0, 0.55): almost level,
  looking along +Y. Objects face the camera on their -Y side.
- Homepage: **50 mm** lens, depth of field on, f/4.5, focused on the target.
- **CLOSE mode** (`CLOSE=1`, used for the door pages and the door PNGs) keeps
  the same camera position and lights. The camera is re-aimed at the centroid
  of the door's mesh bounding boxes, averaged over 8 times in the loop. Depth
  of field is off and the other groups are hidden. Then the frame is fitted in
  four rounds:

  1. Zoom: `lens *= 0.84 / max(x-extent, y-extent)`, measured over 24 times in
     the loop. The door's whole motion fills 84% of the frame's larger side.
  2. Center: `shift_x/shift_y` move the frame onto the motion.

  The result is a long lens (about 178 mm for Keep, 235 mm for Write, 200 mm
  for Speak). That gives the compressed, almost orthographic three-quarter
  portrait.

- Exception: **Switch (move)** was rendered with an earlier CLOSE fit. That
  fit was a single zoom with no shift centering, `cam.lens = 50 * 0.86 /
spread()`, sampled 12 times. It was not re-rendered after the change. A
  re-render with today's script frames it slightly tighter and centered.

## Composition (homepage scene)

Each door is an Empty group at a position, a rotation in degrees and a scale.
The tilt toward the center gives every object a three-quarter view.

| Group             | Location            | Rotation (X, Y, Z) | Scale      |
| ----------------- | ------------------- | ------------------ | ---------- |
| mark (`markroot`) | (0, 0, 1.25)        | (-4, 6, -8)        | radius 1.0 |
| write             | (-3.55, 0.7, 1.85)  | (12, 0, 30)        | 1.1        |
| move              | (3.55, 1.0, 1.95)   | (10, 0, -32)       | 1.1        |
| keep              | (-3.7, -0.9, -2.05) | (-16, 6, 26)       | 1.1        |
| speak             | (3.55, -0.7, -2.05) | (-12, -4, -26)     | 1.0        |

Rules followed:

- Objects float: no floor, no contact shadows. A "Studio floor" variant was
  tried and not chosen. The only shadows are those objects cast on parts of
  themselves (the cards on each other, the window stack).
- Upper doors pitch back (+10 to 12°) and lower doors pitch forward (-12 to
  -16°). Left doors yaw +26 to 30° and right doors -26 to 32°, so each faces
  the mark.
- Orange appears only on the one meaningful detail. Everything else is clay,
  ink or bar grey.

## Materials

Every material is a Principled BSDF with Specular IOR Level 0.5, and every
colour goes through `lin()`. There is **no subsurface, no metallic and no
texture** on any shipped object. The "clay" look comes only from roughness
0.6 to 0.7, smooth shading, bevels and soft light.

The pale palette shipped (`CLAY=pale`, the default):

| Name                | Colour                      | Roughness                                                      | Used for                                                                             |
| ------------------- | --------------------------- | -------------------------------------------------------------- | ------------------------------------------------------------------------------------ |
| clay                | #E6DFD6                     | 0.62                                                           | slabs: note, windows, cards, draft panel                                             |
| bar                 | #BEB4AB                     | 0.70                                                           | placeholder text lines, ghost words, serif captions                                  |
| ink                 | #2A2522                     | 0.50                                                           | text                                                                                 |
| title               | #CFC6BC                     | 0.60                                                           | window title bars (resting), chips, app icon                                         |
| cap                 | #2E2926                     | 0.45                                                           | keycaps                                                                              |
| capink              | #EFE9E2                     | 0.50                                                           | keycap letters                                                                       |
| orange              | #FF4F00                     | 0.45                                                           | the one accent (underline, active title bar, pasted card, level bars, caret, swatch) |
| orangeInk           | #2A0D00                     | 0.50                                                           | text and keycap on the orange card                                                   |
| red / amber / green | #E0685C / #E8B44C / #6DBB5B | 0.50                                                           | window traffic lights                                                                |
| mark                | #FF4F00                     | 0.30, Coat 0.6 (coat roughness 0.15), Emission #FF4400 at 0.35 | the star                                                                             |

The charcoal palette (`CLAY=charcoal`) was considered but not shipped. Its
values: clay #3B3936, bar #5A5652, ink #E2DCD4, title #4A4744, cap #1E1D1C,
capink #E2DCD4. The script also defines `wall`, `relief` and `iron`. These are
left over from a field-line background that was rejected, and no shipped
object uses them.

Fades are done by animating the Principled **Alpha** input on per-object copies
of a material (`own()`, `alpha()`). Colour changes animate Base Color
(`color()`).

## Object vocabulary

- **Rounded slab** (`rrect`): a rounded rectangle in the XZ plane, extruded
  along Y with its front at -Y. Corners use 10 segments. A 4-segment Bevel
  modifier (angle limit 40°, width ≤ 45% of depth) plus a Weighted Normal
  modifier give it smooth shading. Typical sizes, in scene units:

  - note: 2.1 × 1.45 × 0.05, radius 0.05
  - window: 1.6 × 1.08 × 0.05, radius 0.07
  - card: 1.12 × 0.74 × 0.035, radius 0.07
  - draft panel: 2.6 × 0.98 × 0.07, radius 0.16

  Placeholder text is pill bars 0.055 to 0.06 tall, 0.012 deep, with no bevel.

- **Keycap** (`keycap`): a dark slab, s·1.15 × s × 0.03, radius 0.24·s, with a
  centered JetBrains Mono letter at 0.62·s.
- **Text** (`text`): Blender font curves, **flat** (`extrude = 0`, whatever the
  argument says). They lie 2.8 mm in front of the surface (`+0.0028` on Y from
  a -0.03 offset). Sizes: 0.19 for the Write line, 0.075 to 0.16 elsewhere.
- **Spheres**: UV spheres, 24×12, smooth. Used for the traffic lights and the
  draft's status dot.
- **The mark**: the star from `Mark.swift`, rebuilt in 3D. It is twelve
  pentagonal pyramids on a dodecahedron's faces, apex at 3.05, turned (24°,
  -18°, 8°) as in Swift, with flat shading so the facets read. It is solid
  glossy orange, not glass.

### Fonts

Use static TTFs only. Blender renders the Mac's variable fonts with holes in
the letters. This happened with SF, New York, and Google's variable-axis
Inter, which is why the session switched mid-way.

- sans: **Inter Medium, static**, from rsms/inter v4.1:
  `curl -sL -o inter.zip https://github.com/rsms/inter/releases/download/v4.1/Inter-4.1.zip && unzip -o -j inter.zip extras/ttf/Inter-Medium.ttf`
- mono: **JetBrains Mono Regular**, `~/Library/Fonts/JetBrainsMono-Regular.ttf`
  (`ADV = 0.6` em advance is assumed for the draft's word layout)
- serif: **Newsreader Italic 400** (static instance from Google Fonts).
  Request `https://fonts.googleapis.com/css2?family=Newsreader:ital,wght@1,400`
  with `-A "Mozilla/4.0"` so it returns a `.ttf` URL. Save it as
  `Newsreader_ital_wght_1_400.ttf`.

Put the sans and serif files in `tools/doors/fonts/`, or set `FONT_DIR`.

## The doors and their loops

Every loop is periodic in T, and frames 0 to T·24−1 are rendered, so frame
T·24 would equal frame 0. On top of each door's own action, each group sways
gently (`floating`): exactly one cycle per T, ±1.2° pitch, ±1.6° yaw, ±0.03 in
z, with a per-door phase. That keeps every loop seamless.

| Door          | T    | Frames | Action                                                                                                                                                                                                                                                                                                             | Still frame used for the PNG           |
| ------------- | ---- | ------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | -------------------------------------- |
| write         | 6 s  | 144    | An orange underline draws under "tomorow" (0.4 to 1.5 s). At 2.7 to 3.1 s the word cross-fades to "tomorrow", "at ten." slides right to make room, and the underline fades. At 4.9 to 5.5 s the typo returns.                                                                                                      | f0040 (underline drawn under the typo) |
| move (Switch) | 9 s  | 216    | Three windows (Mail M, Notes N, Browser B) in a staggered stack. Every 3 s the back one swings around (an arc of -0.95 x, +0.28 z) to the front, and its title bar blends from title grey to orange. Clipping through each other was accepted.                                                                     | f0000                                  |
| keep          | 8 s  | 192    | Four cards: a time (F), a colour (D, "#FF4F00 / International Orange"), units (S, "12 ft / 3.66 m") and an orange note (A, "Notes for Thursday: …"). The orange card lifts toward the camera and settles back, then the colour card slides **up** and returns. It first slid down and out of frame, and was fixed. | f0040                                  |
| speak         | 8 s  | 192    | The draft panel: Messages icon, INSERT chip, five orange level bars, a rule. Words of "Let's move the review to Friday, / and send the draft." arrive every 0.38 s, grey (ghost) while new and ink once settled. An orange caret follows and the meter bounces. All of it fades at 5.6 to 6.3 s.                   | f0110                                  |
| mark          | 30 s | 720    | One full turn about a tilted axis (12°, -25°, 1), plus a 0.04 bob. It is a quaternion, so the loop closes.                                                                                                                                                                                                         | (homepage only)                        |

The pose is driven by `bpy.app.handlers.frame_change_pre` →
`pose(frame / 24)`. `ONLY=<n>` renders a single frame.

## Exact commands

The original working directory was the session scratchpad's `float/`
directory, with `doorpages/` beside it. `B=/Applications/Blender.app/Contents/MacOS/Blender`.

Homepage loops (`render_loops.sh`), cropped to motion:

```sh
for k in markroot write move keep speak; do
  $B -b -P scene3.py -- $k $PWD/r3 2000 64 > r3-$k.log 2>&1
done
```

Door-page close-ups (`render_close.sh`). These frames are also the source of
the door PNGs:

```sh
for k in write keep speak move; do
  CLOSE=1 CW=1200 CH=900 $B -b -P scene3.py -- $k $PWD/r4 1200 48 > r4-$k.log 2>&1
done
```

Close-ups took about 9 to 10 s per frame on this Mac, about 2.5 h for all
four. Homepage loops took about 2.7 s per frame.

Door PNGs, run from the lodestar repo root (transcript line 13764):

```sh
S=<scratchpad>/float/r4
for spec in write:0040 switch:0000 keep:0040 speak:0110; do
  k=${spec%%:*}; f=${spec##*:}; src=$k; [ $k = switch ] && src=move
  sips -Z 360 $S/$src/f$f.png --out packaging/doors/door-$k.png
done
```

`make-app.sh` copies them into `Contents/Resources/`.

Close-up encodes (`encode_close.sh <door…>`, output to
`doorpages/close-<k>.*`, then copied to `lodestar-site/public/media/doors/`
with move renamed to switch):

```sh
ffmpeg -y -loglevel error -framerate 24 -start_number 0 -i float/r4/$k/f%04d.png \
  -c:v libvpx-vp9 -pix_fmt yuva420p -crf 32 -b:v 0 -row-mt 1 -deadline good -an doorpages/close-$k.webm
ffmpeg -y -loglevel error -framerate 24 -start_number 0 -i float/r4/$k/f%04d.png \
  -c:v hevc_videotoolbox -alpha_quality 0.8 -q:v 60 -tag:v hvc1 -movflags +faststart -an doorpages/close-$k.mp4
cwebp -quiet -q 82 -alpha_q 90 float/r4/$k/f0000.png -o doorpages/close-$k.webp
```

Homepage encodes (`encode.sh`, to `site3/`, then to
`lodestar-site/public/media/hero/`, with markroot renamed mark and move
renamed switch):

- VP9: `-crf 31`.
- HEVC: `-alpha_quality 0.8 -q:v 62` into `.mov`. Each `.mov` was then
  re-wrapped as `.mp4` with
  `ffmpeg -i k.mov -c copy -tag:v hvc1 -movflags +faststart k.mp4`, because
  artifacts would not serve `.mov`.
- WebP poster: `cwebp -q 82 -alpha_q 90`.
- The 30 s mark was re-encoded lighter: VP9 `-crf 38`, HEVC
  `-alpha_quality 0.7 -q:v 48`.

Format rationale: VP9 with alpha for Chrome and Firefox, HEVC with alpha
(`hvc1`, `.mp4`) for Safari, and a WebP poster from frame 0.

## What the user said

Liked:

- The Blender renders for the doors: "looks really good … we should use it
  for most of our images."
- Pale over charcoal clay, because it "contrasts against the background
  better."
- "Some of the lighting reflect[ing] from the logo." This became the 90 W
  core light, kept to a hint.
- Subtle motion that makes the doors "feel like they're there, but not too
  dominant."
- Floating in space, done in a way that is not a boring bob.
- A "Superhot … not as geometric, kind of like Blender" look that stays
  professional, "not gimmicky or LARPy."
- Rendered loops, over flat layers drifting.

Rejected:

- Pointer parallax.
- A plain background, and later the carved field-line wall as "too
  corporate." A charcoal ground was also wrong. The site settled on a simple
  turning star field behind the renders.
- A mark loop that "goes in one direction and then resets". Loops must be
  seamless, which led to the full quaternion turn.
- A speck where the underline sat before it began drawing. This was fixed:
  underline alpha is 0 before t = 0.4.
- Keep's colour card leaving the frame.

Accepted as is: Move's windows clipping through each other ("fine because you
don't want to go out too far").
