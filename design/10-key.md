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
| standard | 24     | 21 + 3      | key, 13 semibold          | every key in a row, a footer, a guide, a card |
| large    | 36     | 31 + 5      | large figure, 23 semibold | the peek, the meeting's countdown             |

### Width

A key is as wide as its legend plus 8 at each side (a grid step), and never narrower than it is tall: a single letter stands on a square key, 24 wide. There is no other minimum. Keys that are not one sequence stand 8 apart.

### The legend

- **Centred on the face,** not the whole key: the side is below the face and is not part of where the legend sits.
- **One band per key, ignoring descenders.** A legend with no capitals, digits or symbols is centred on its x-height band; any other legend on its cap-height band. A `g`, `j`, `p` or `y` never moves its key's legend; a row of keys shares one baseline.
- **Punctuation** alone on a key (`'`, `` ` ``, `;`, `/`, `.`, `,`) is drawn larger, at the title step of the type scale (18, semibold), because at the letters' size it is a speck. It stands on the cap-height band of its own font like any other legend that is not lowercase, so a `,` and a `.` sit low, a `'` and a `` ` `` high and a `-` in the middle, as on a real keycap; it is never centred by its ink up and down, which made every mark a floating blob.
- **Across,** a legend is centred by its ink (punctuation too).

### What a key says

- **A bare keystroke is shown as typed:** lowercase. A capital appears only where Shift is actually pressed.
- **A chord with modifiers** follows macOS: the modifiers' glyphs, then the letter as a capital, on one key (`⌘K`, `⌥J`, `⌥⇧⌘V`).
- **Named keys** are words where macOS uses words (`esc`, `tab`, `space`, and Lodestar's own `lode`) and glyphs where it uses glyphs (`⏎`, `⌫`, `⇧`, `⌘`, `⌥`, `⌃`, `↑ ↓ ← →`).
- **A sequence** (keys pressed one after another) is one key per keystroke, 4 apart: `e` `p`, never a chip reading "e p". This holds for click hints too, on trial: a screen of hints is the dense case, and its render decides whether hints keep it (see Open).
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

Built 23 October 2026. Before it, main drew keys in seven places (`KeyFace`, `MarkKey`, `KeyMark`, Keep's `placedCap`, the ⌘K card's `keycap`, Settings' and the walk's own `keycap`) at 22 tall and at least 34 wide, a sequence as one chip ("e p"), bare keystrokes in capitals on Keep's cards, the guide, hint marks, flashes ("Breath JK saved") and the coach ("lode F → Figma"), a double tap as two identical keys, and the large key's figure left of centre. Now `Key` (`Key.swift`) is the one key: `KeySize` (standard 24 = 21 + 3, large 36 = 31 + 5) and `KeyState` (resting, lit, pressed, quiet) are values, `KeyStrokes` draws a sequence (4 apart), a double tap (`×2` on the key's own baseline) and keys that are not one sequence (8 apart), and `KeyMark` draws hints and the peek from it. The legend is set by CoreText from the font's metrics (`KeyLegend`), never by a text field's line box.

Measured by rendering every legend in every state and both looks and reading the ink back (`KeyTests`):

- `a g y e s A ⏎ ⇧ 1 esc ⌘K ' ;` are centred across the face within 0.5 pt and their band (x-height or cap height) is centred on the face within 0.5 pt; lowercase legends share a baseline within 0.5 pt whatever their descenders, in all four states and both looks.
- A key is `ceil(ink) + 16` wide, square (24) at the least; `a`, `i`, `l`, `1`, `'` are all 24, `esc` 38, `⌘K` 36, `lode` 42 (day).
- Punctuation is drawn at 18 semibold on the cap band: a `,` and a `.` have their ink centre below the face's centre, a `'` and a `` ` `` above it, a `'` and a `,` at least 3 pt apart, and every mark is centred across by its ink and its band on the face within 0.5 pt, in both looks.
- The large key's figure is centred on its face (`7`, `3`, `10`) within 0.5 pt.
- Every key on every gallery surface, in both looks, is as wide as its legend needs and no wider, spaces no letters, and has no identical `lode` beside it.

What the build found and decided:

- **A quiet key stands where the resting face stands.** Its hairline outlines the 21-point face, not the whole 24, so a row of mixed states shares one baseline. Over another app's window (a typed hint) a quiet key keeps the pane's own step behind its letter, or the content would run through it.
- **Keep's cards** lost two points of body to the taller key; the gap under the key went from 4 to 2 (the key's own side is part of it) so the file's sheet still fits, and every title on a card now stands on the middle of its key's face.
- **Guides and the cheat sheet** write a key as groups: `zo zc` is two sequences, `h j k l` four keys 8 apart, `esc`, `⌘K`, `⇧F` and `a…z` one key each.
- **`uppercased()`** on a bare keystroke is gone from flashes, the coach, the advisor, the config history, the launcher's verdicts, Keep's cards and the guides; the ones that remain are chords (⌥J, ⇧⌘V), VoiceOver's speech, or not keystrokes, and a source test lists each with its reason.
- **Chips that are read** (Ask's profile, the commands bar's source, the meeting's unit) are not keys and keep their own view; the drift test names them, and the list only shrinks.

Click hints, on trial: `hints-dense-{day,night}` lays 55 hints over a busy page (nav, sidebar, tabs, filters, ten rows, a rail), and `hints-dense-oneKey-{day,night}` draws the same hints as one key each for comparison. Two keys a hint are 52 wide and cover on average 58 percent of the width of the thing they point at (19 of 55 cover it whole); one key is 27.5 wide, 40 percent, 6 of 55 whole. Neither makes hints overlap each other. See Open.

## Prototype lessons

- **Mind the axis.** AppKit counts y downward in a layout constant and upward in a view: the prototype's lift put the legend lower, not higher.
- **Line boxes lie.** A text field centres its line, not its letters; the legend has to be placed from the font's x-height and cap height.
- **Ink boxes lie too.** Centring each legend's own ink moved `g` and `y` up; one band per kind keeps the baseline.

## Main lessons

- **One drawing, one place.** Seven keys meant seven centrings: a text field per key, each with its own constant. A key that draws its legend itself, from the font's metrics, cannot disagree with another.
- **Test the ink, not the frame.** A legend's frame can be centred while its letters are not. The tests render the key with and without its legend and measure the pixels that differ.
- **A taller key moves what stands beside it.** Two points on the key took two points from Keep's cards' bodies, which a file's sheet had filled exactly.
- **Display and data share a string.** `uppercased()` on a letter was used to show a key and, nearby, to say a chord's capital or what VoiceOver reads; each was read, and a test lists the survivors.

## Open

- **Click hints on trial.** A screen of hints shows dozens of two-letter sequences; drawn as two keys each, they may crowd the screen and hide what they point at. If the dense render says so, a hint alone may draw its sequence as one key with the letters set tight (`sd`), because a hint is a name to type rather than a key to find. Decided by the render, not in advance. The build drew both (see Status); the numbers there are the evidence, and the choice is the owner's.
- **Pressed in the dark look** is hard to see: the side is close to the ground, so losing two points of it barely shows. Acceptable for now; noted for the slab and sound, which also mark a press.

## Decided in review

- **More room** (23 October 2026): the first draft (22 tall, 6 each side) felt cramped; the key is 24 tall with 8 each side, and separate keys stand 8 apart.
- The large key, centred, and the four states are approved as drafted.
