# 01 · Colour

Two grounds, one colour, and the rules that keep every pair readable at every hour. Everything Lodestar draws takes its colour from here, through one theme call; nothing reaches for a system colour.

## What it is for

Colour in Lodestar says three things and nothing else:

- **Which look you are in.** Clay by day, espresso by night.
- **What is chosen.** The chosen thing is a slab of the other look's ground (each look is the other's selection).
- **Where the hand goes next.** International Orange, on the key to press, the switch that is on, and the cursor.

Colour never decorates, never sorts content into categories, and never carries meaning alone: whatever orange says, a shape or a word also says.

## Origin

- **Grounds.** Decided on 20 October 2026 on the canvas "Lodestar Design Languages". Clay as it was leaned pink beside the night's brown, so it was warmed a few degrees toward espresso until the two read as one family. A saturated ground (sage, forest) was more striking and worse to live in; Lodestone, a cold blue-grey night, shipped and was retired for the same reason. A ground is lived in for hours, not admired.
- **One colour.** The Mac's accent, viridian, saffron, British Racing Green and moss were all drawn beside International Orange. The one owned colour was the stronger brand and the better light. The accent setting retires.
- **Adapted, not copied** (22 October 2026). Three pairs were drawn on both grounds: the literal pair (the true `#FF4F00` at night, the same hue deepened by day), a matched pair and a softer one. The literal night orange sits at the edge of the screen's gamut and glows on espresso; the literal day orange reads as rust. The softer pair turned coral at night. The matched pair was chosen because the eye reads it as one colour in both looks.
- **The ceiling.** Pure white and pure black glare: positive polarity reads best (Piepenbrock, NN/g), but at full white it is the brightest thing on the screen. So nothing is pure white or pure black, and the day pane sits near 95 per cent lightness.

## Values

Lightness (L), chroma (C) and hue (h) are OKLab. Every value here is chosen by eye and then measured; none is derived from a formula.

### Clay (day)

| Step      | Hex        | L     | Role                                            |
| --------- | ---------- | ----- | ----------------------------------------------- |
| ground    | `#EDE4DA`  | 0.923 | behind panes; the slab by night                 |
| pane      | `#F6EFE8`  | 0.956 | what a surface is made of                       |
| key       | `#FCF8F4`  | 0.981 | a key's face; the lightest thing Lodestar draws |
| side      | `#DCCEC1`  | 0.859 | the side a key stands on                        |
| ink       | `#1E1814`  | 0.215 | text that is read                               |
| quiet ink | `#66584E`  | 0.471 | captions, legends, what is said about a thing   |
| slab      | `#2A221D`  | 0.259 | the chosen thing, by day                        |
| slab side | `#120D0A`  | 0.164 | the side the slab stands on                     |
| hairline  | ink at 10% |       | an edge                                         |

### Espresso (night)

| Step      | Hex       | L     | Role                        |
| --------- | --------- | ----- | --------------------------- |
| ground    | `#120F0C` | 0.171 | behind panes                |
| pane      | `#1D1916` | 0.217 | what a surface is made of   |
| key       | `#2B2622` | 0.273 | a key's face                |
| side      | `#110E0C` | 0.167 | the side a key stands on    |
| ink       | `#F1EBE2` | 0.942 | text that is read           |
| quiet ink | `#A99F92` | 0.707 | captions, legends           |
| slab      | `#F1E8DF` | 0.936 | the chosen thing, by night  |
| slab side | `#ADA093` | 0.713 | the side the slab stands on |
| hairline  | ink at 8% |       | an edge                     |

Every step of both looks sits between hue 53 and 78 with chroma under 0.025: one warm family, never a colour of its own.

### International Orange

| Look  | Hex       | L     | C     | h   |
| ----- | --------- | ----- | ----- | --- |
| Night | `#FA5617` | 0.670 | 0.210 | 38  |
| Clay  | `#C83500` | 0.550 | 0.190 | 36  |

Each look's orange is the best version of International Orange for its own ground, not the same hex. At night it steps just inside the gamut edge, so it does not glow against espresso and does not soften into coral. By day it must be deep enough to be read as text on clay, and it leans two degrees toward red, which keeps its chroma at that depth, so it reads as the bridge's red-orange rather than rust. The two are judged by eye side by side and then measured. One value per look: an earlier pair, a brighter orange for fills and a deeper one for text, made one light two colours on one page.

**A letter on the orange** takes whichever of the clay key face (`#FCF8F4`) and clay ink (`#1E1814`) measures higher on it: the key face on clay's orange (5.01 : 1), the ink on night's (5.36 : 1). White on night's orange is 3.3 : 1, which is why the rule measures rather than assumes.

**On the slab**, the things inside take the slab's look, so a lit key on the day slab is night's orange and on the night slab clay's orange.

### Measured contrast

| Pair                       | Clay  | Espresso |
| -------------------------- | ----- | -------- |
| ink on ground              | 13.97 | 16.12    |
| ink on pane                | 15.41 | 14.73    |
| ink on key                 | 16.62 | 12.63    |
| quiet ink on ground        | 5.44  | 7.33     |
| quiet ink on pane          | 6.00  | 6.70     |
| quiet ink on key           | 6.47  | 5.75     |
| orange on pane (as text)   | 4.65  | 5.33     |
| orange on key              | 5.01  | 4.57     |
| other look's ink on slab   | 13.18 | 14.51    |
| other look's quiet on slab | 5.99  | 5.65     |
| orange on slab (as a fill) | 4.76  | 4.38     |

### Shadow

A shadow is never black: by day it is clay's quiet ink, by night espresso's ground, each at the share the material contract sets. Until then they replace the old warm browns at the old shares.

### Until the slab

The slab is its own contract. Until it lands, a chosen row stands on the look's key step as it stood on the old raised step, and its keys light. The key step and the chosen row are then the same colour, told apart by a key's side and edge; the slab contract retires this.

## Rules

1. **One theme call.** Every colour comes from the theme, which resolves the palette for the view's own look. No surface names a hex, a system colour (`labelColor`, `controlAccentColor`, `systemX`, `white`, `black`) or a material.
2. **The ceiling.** No step is pure white or pure black. Day panes sit near 0.95 L, night panes near 0.22 L.
3. **The floors.** Text read at length clears 7 : 1. Every other text clears 4.5 : 1. A fill that carries meaning (a lit key, a switch that is on) clears 3 : 1 against what it sits on. These hold at every hour (see Eye comfort).
4. **Orange is rare.** It appears only on the key to press, the switch that is on and the cursor. Two lit things in one view means one of them is wrong.
5. **Content keeps its colour.** A clip's swatch, an image, an app icon, a page preview: drawn exactly as they are, at every hour, on every ground.
6. **Never tinted.** Colour temperature belongs to Night Shift. Lodestar moves lightness, never hue.
7. **No gradients.** A surface is one colour. A gradient is allowed only where it is the content (an image) or a mask that never reads as a colour of its own.
8. **The two looks are one family.** A step in one look and its counterpart in the other share a hue within 25 degrees (the inks are the widest pair, at 22.6).

## Enforcement

- A drift test reads the sources and fails on any system colour, hex literal or material outside the theme.
- A palette test holds both looks to the ceiling (no step at L above 0.99 or below 0.15) and to every floor in the table above.
- A test holds the letter-on-orange rule: the chosen ink measures higher than the other candidate, and clears 4.5 : 1.

## Renders

`foundation-colour-day`, `foundation-colour-night`: every step as a swatch with its hex and lightness, and every pair above with its measured ratio, drawn from the theme's values, so the sheet is the code.

## Status

Not yet built. The colour sheet rendered from main (`foundation-colour-day`, `foundation-colour-night`) shows what this contract replaces:

- **The palettes are the previous ones:** a warm-grey night (ground `#18130E`, pane `#221D19`, raised `#2E2925`) and clay (ground `#EFE7DE`, pane `#F8EFE7`, raised `#FFFBF6`), with a separate dark clay key (`#2E2926`).
- **The ceiling is broken:** a key's face, its top edge, the mark's face and the letter on the orange are pure white (`#FFFFFF`).
- **Ink is the system's:** text is `labelColor` (`#262523` over the day pane), not a palette step.
- **The accent is a setting,** the Mac's own by default, and Lodestar's orange is the literal pair (`#FF4F00`, `#C43B00`).
- **The glass tint** (`#EBEBEB` by day) is a neutral grey, outside the warm family.

## Prototype lessons

- **Every label must take the palette's ink.** A text field that sets no colour falls back to the system's label colour, which is pure black or white. The prototype fixed this with one label factory; a test should fail on any text that has no theme colour.
- **Colours baked as CGColor go stale.** A layer colour resolved once keeps the look it was made in, so a slab row flipping to the other look left dots and chips in the old one. Resolve layer colours in the draw pass, under the view's own appearance.
- **Measure, then judge by eye.** The values above passed every test before anyone saw them; what the tests cannot see (clay looking grey in the evening, a calmer orange reading as salmon) only showed in renders. Every change to a value is rendered before it lands.

## Decided in review

- Night keys keep their step (`#2B2622`); the key's side, in the key contract, does the standing.
- One orange per look, also on the slab: a lit key on the night slab is clay's orange, which clears the 3 : 1 floor for a fill (4.38) and carries its letter at 5.01.
