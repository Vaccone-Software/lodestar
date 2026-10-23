# 10 · The key

The one thing only Lodestar has. A key is drawn wherever Lodestar asks the hand to press something: a face on a side, its legend the key as typed, as wide as what it says.

## What it is for

Lodestar is driven from the keyboard, so the key is its vocabulary: a launcher row's address, a Settings row's letter, a footer's ⏎, a card in Keep, a hint on the screen. When every key is drawn the same way, the eye learns one shape and finds it everywhere. When a key is drawn wrong (a letter off its centre, a capital where none is typed, two keystrokes squeezed into one chip), the hand hesitates.

## Origin

- **Built on the foundations:** the key role (13 semibold) from type, the control rung (8.4) and the half-step padding from geometry, the face-on-a-side from material, the orange from colour.
- **The prototype's audit** (21 October 2026) found every failure this contract forbids: lowercase letters riding high and capitals low in the same row, punctuation drawn tiny, "e p" as one chip with spaced letters, capitals on Keep's cards and in the guide though they are typed bare, a single letter on a key 34 points wide, and the large key's figure set left of centre. The causes were a centring lift with its sign reversed, text centred by its line box rather than its letters, and ink-box centring that moved a key with a descender.

## Values

### Sizes

| Size     | Height | Face + side | Legend role               | Used for                                      |
| -------- | ------ | ----------- | ------------------------- | --------------------------------------------- |
| standard | 22     | 19 + 3      | key, 13 semibold          | every key in a row, a footer, a guide, a card |
| large    | 36     | 31 + 5      | large figure, 23 semibold | the peek, the meeting's countdown             |

### Width

A key is as wide as its legend plus 6 at each side (the half-step), and never narrower than it is tall: a single letter stands on a square-ish key, 22 wide. There is no other minimum.

### The legend

- **Centred on the face,** not the whole key: the side is below the face and is not part of where the legend sits.
- **One band per key, ignoring descenders.** A legend with no capitals, digits or symbols is centred on its x-height band; any other legend on its cap-height band. A `g`, `j`, `p` or `y` never moves its key's legend; a row of keys shares one baseline.
- **Punctuation** alone on a key (`'`, `` ` ``, `;`, `/`, `.`) is drawn larger, its ink about the face's cap height, and centred by its ink, because at the letters' size it is a speck.
- **Across,** a legend is centred by its ink.

### What a key says

- **A bare keystroke is shown as typed:** lowercase. A capital appears only where Shift is actually pressed.
- **A chord with modifiers** follows macOS: the modifiers' glyphs, then the letter as a capital, on one key (`⌘K`, `⌥J`, `⌥⇧⌘V`).
- **Named keys** are words where macOS uses words (`esc`, `tab`, `space`, and Lodestar's own `lode`) and glyphs where it uses glyphs (`⏎`, `⌫`, `⇧`, `⌘`, `⌥`, `⌃`, `↑ ↓ ← →`).
- **A sequence** (keys pressed one after another) is one key per keystroke, 4 apart: `e` `p`, never a chip reading "e p".
- **A double tap** is one key followed by `×2` in quiet ink at the meta size, 4 after it: `lode` ×2.
- **A key named in a sentence** (a flash, a caption, the coach) is drawn as a key, inline, or written as typed; never capitalised to stand out.

### States

| State   | Face                | Side                     | Legend        | When                                     |
| ------- | ------------------- | ------------------------ | ------------- | ---------------------------------------- |
| resting | the look's key step | the look's side, 3 (5)   | ink           | a key you can press                      |
| lit     | the orange          | the orange, darkened     | ink on orange | the one key to press next                |
| pressed | as before           | 1, face down by the rest | as before     | while it is down, at once                |
| quiet   | none, a hairline    | none                     | quiet ink     | shown but not pressable now, or disabled |

On the slab (the chosen row) a key takes the slab's look; the slab contract sets it.

## Rules

1. **One key, everywhere.** Every place Lodestar draws a key uses this primitive; no surface draws its own.
2. **On its face, on one band.** Legends sit on the face, centred by band, so a row of keys shares a baseline.
3. **As typed.** Lowercase for a bare keystroke; capitals only for Shift, and in a modifier chord.
4. **One keystroke, one key.** Sequences are separate keys; a double tap is one key and ×2.
5. **One lit key at a time.** The orange marks where the hand goes next; a second lit key means one is wrong (a chord's keys, pressed together, count as one).
6. **Hugs its legend.** No minimum width beyond square.
7. **Instant.** Pressing and lighting do not animate (motion contract).

## Enforcement

- Rendered-legend tests: for a set of legends (`a`, `g`, `y`, `e`, `s`, `A`, `⏎`, `⇧`, `1`, `esc`, `⌘K`, `'`, `;`) in every state and both looks, the legend's band is centred on the face within 0.5 pt, and lowercase legends share a baseline within 0.5 pt.
- A source test fails on `uppercased()` applied to a bare keystroke shown on a key or in a flash.
- A gallery test: no key is wider than its legend plus padding (or square), no key's text contains a space between single letters, and no view shows two identical keys in a row where a double tap is meant.
- The drift test fails on a surface drawing a key-shaped view of its own.

## Renders

`keycaps-all-{day,night}`: every legend kind, every state, both sizes, sequences, a double tap and a chord. Then every surface with keys.

## Status

Not yet built. Main draws keys at least 34 wide, a sequence as one chip ("e p"), bare keystrokes in capitals on Keep's cards, the guide, hint marks and flashes ("Breath JK saved"), a double tap as two identical keys, and the large key's figure left of centre.

## Prototype lessons

- **Mind the axis.** AppKit counts y downward in a layout constant and upward in a view: the prototype's lift put the legend lower, not higher.
- **Line boxes lie.** A text field centres its line, not its letters; the legend has to be placed from the font's x-height and cap height.
- **Ink boxes lie too.** Centring each legend's own ink moved `g` and `y` up; one band per kind keeps the baseline.

## Open

- Whether the standard key should keep 22 or grow to 24 now that rows are 48 and fields 23.
