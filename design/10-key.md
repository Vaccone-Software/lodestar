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

- **Centred on the face.** The legend sits on the face, which is the top of the key; layout centres the whole key, face and side together (rule 8).
- **One band per key, ignoring descenders.** A legend with no capitals, digits or symbols is centred on its x-height band; any other legend on its cap-height band. A `g`, `j`, `p` or `y` never moves its key's legend; a row of keys shares one baseline.
- **Punctuation** alone on a key (`'`, `` ` ``, `;`, `.`, `,`) is drawn larger, at the title step of the type scale (18, semibold), because at the letters' size it is a speck. A `/` is not a speck: it stands as tall as a capital, and drawn larger it filled its key and hung below the word beside it, so it keeps the letters' size. It stands on the cap-height band of its own font like any other legend that is not lowercase, so a `,` and a `.` sit low, a `'` and a `` ` `` high and a `-` in the middle, as on a real keycap; it is never centred by its ink up and down, which made every mark a floating blob.
- **Across,** a legend is centred by its ink (punctuation too).

### What a key says

- **A bare keystroke is shown as typed:** lowercase. A capital appears only where Shift is actually pressed.
- **A chord with modifiers** follows macOS: the modifiers' glyphs, then the letter as a capital, on one key (`⌘K`, `⌥J`, `⌥⇧⌘V`).
- **Named keys** are words where macOS uses words (`esc`, `tab`, `space`, and Lodestar's own `lode`) and glyphs where it uses glyphs (`⏎`, `⌫`, `⇧`, `⌘`, `⌥`, `⌃`, `↑ ↓ ← →`).
- **A sequence** (keys pressed one after another) is one key per keystroke, 4 apart: `e` `p`, never a chip reading "e p". The one exception is a click hint: a hint is a name to type, not a key to find, so its letters share one key, set tight (`JK`), and the letters already typed go quiet inside it (see Decided in review). A hint in select, the click door or the aim band is picked with Shift, which opens the pick and may stay held through it, so its letters are capitals: what the hand presses, and a capital `L` is never read as an `I`. A tag in the editor's lens is picked with the bare letter and stays lowercase.
- **A double tap** is one key followed by `×2` in quiet ink at the meta size, 4 after it: `lode` ×2.
- **A key named in a sentence** (a flash, a caption, the coach) is drawn as a key, inline, or written as typed; never capitalised to stand out.

### States

| State   | Face                | Side                     | Legend        | When                                     |
| ------- | ------------------- | ------------------------ | ------------- | ---------------------------------------- |
| resting | the look's key step | the look's side, 3 (5)   | ink           | a key you can press                      |
| lit     | the orange          | the orange, darkened     | ink on orange | the one key to press next                |
| quiet   | none, a hairline    | the hairline's tone      | quiet ink     | shown but not pressable now, or disabled |

**Pressed is not a state.** No surface draws a key pressed. It is the pointer's response: while the mouse is down on a key that can be clicked, the side gives up the rest (to 1 point) and the face goes down by it, at once; on release the key stands again. The frame does not move. A key that cannot be clicked never does it.

On the slab (the chosen row) a key takes the slab's look, face, side and hairline (a key on the day slab is a night key, on the night slab a clay key), and the lit key is that look's orange with its letter. Only the key that acts is lit on a slab, and the address keys rest (design/11-slab.md).

## Rules

1. **One key, everywhere.** Every place Lodestar draws a key uses this primitive; no surface draws its own.
2. **On its face, on one band.** Legends sit on the face, centred by band, so a row of keys shares a baseline.
3. **As typed.** Lowercase for a bare keystroke; capitals only for Shift (a hint picked with it), and in a modifier chord.
4. **One keystroke, one key.** Sequences are separate keys; a double tap is one key and ×2. A click hint alone draws its letters in one key.
5. **One lit key at a time.** The orange marks where the hand goes next; a second lit key means one is wrong (a chord's keys, pressed together, count as one).
6. **Hugs its legend.** No minimum width beyond square.
7. **Instant.** Pressing and lighting do not animate (motion contract).
8. **Centred as one object.** Layout sees the whole key, face and side: a key is 24 tall (36 large), has no alignment insets, and a row that centres it centres the key. The side is a solid, hard-edged band, so the eye reads it as part of the key; a soft shadow is not, and layout leaves a shadow out. Words beside a key stand on the key's legend baseline (design/13-row.md), so a key and its words move together.

## Enforcement

- Rendered-legend tests: for a set of legends (`a`, `g`, `y`, `e`, `s`, `A`, `⏎`, `⇧`, `1`, `esc`, `⌘K`, `'`, `;`) in every state and both looks, the legend's band is centred on the face within 0.5 pt, and lowercase legends share a baseline within 0.5 pt.
- A source test fails on `uppercased()` applied to a bare keystroke shown on a key or in a flash.
- A gallery test: no key is wider than its legend plus padding (or square), no key's text contains a space between single letters, no key but a hint holds several bare letters, and no view shows two identical keys in a row where a double tap is meant.
- The drift test fails on a surface drawing a key-shaped view of its own.

## Renders

`keycaps-all-{day,night}`: every legend kind, every state, both sizes, sequences, a double tap and a chord. Then every surface with keys.

## Status

Built 23 October 2026. Before it, main drew keys in seven places (`KeyFace`, `MarkKey`, `KeyMark`, Keep's `placedCap`, the ⌘K card's `keycap`, Settings' and the walk's own `keycap`) at 22 tall and at least 34 wide, a sequence as one chip ("e p"), bare keystrokes in capitals on Keep's cards, the guide, hint marks, flashes ("Breath JK saved") and the coach ("lode F → Figma"), a double tap as two identical keys, and the large key's figure left of centre. Now `Key` (`Key.swift`) is the one key: `KeySize` (standard 24 = 21 + 3, large 36 = 31 + 5) and `KeyState` (resting, lit, quiet) are values, `KeyStrokes` draws a sequence (4 apart), a double tap (`×2` on the key's own baseline) and keys that are not one sequence (8 apart), and `KeyMark` draws hints and the peek from it. The legend is set by CoreText from the font's metrics (`KeyLegend`), never by a text field's line box.

Measured by rendering every legend in every state and both looks and reading the ink back (`KeyTests`):

- `a g y e s A ⏎ ⇧ 1 esc ⌘K ' ;` are centred across the face within 0.5 pt and their band (x-height or cap height) is centred on the face within 0.5 pt; lowercase legends share a baseline within 0.5 pt whatever their descenders, in all three states and both looks.
- A key is `ceil(ink) + 16` wide, square (24) at the least; `a`, `i`, `l`, `1`, `'` are all 24, `esc` 38, `⌘K` 36, `lode` 42 (day).
- Punctuation is drawn at 18 semibold on the cap band: a `,` and a `.` have their ink centre below the face's centre, a `'` and a `` ` `` above it, a `'` and a `,` at least 3 pt apart, and every mark is centred across by its ink and its band on the face within 0.5 pt, in both looks.
- The large key's figure is centred on its face (`7`, `3`, `10`) within 0.5 pt.
- Every key on every gallery surface, in both looks, is as wide as its legend needs and no wider, spaces no letters, and has no identical `lode` beside it.

What the build found and decided:

- **A quiet key is a resting key left unfilled.** It keeps the resting key's shape exactly: a 21-point face, outlined by a hairline and filled with nothing (the surface shows through), standing on a 3-point side in the hairline's tone. Its letter, in quiet ink, is centred on the face as every key's is, so it is the same size and shape as its neighbours and shares their baseline. (Until the row contract, 23 October 2026, it outlined only the face with no side and read as a smaller key.)
- **The quiet key was built with the row contract** (23 October 2026). `Standing` draws it outlined: the face unfilled with a hairline, the side a crescent beneath it (the band's shape less the face's) in the hairline's tone, at 3 points (5 large), never pressed by the pointer. The material depth sweep reports it as `outlined(side:)`: not `flat`, since it keeps a side, and not `standsUp`, since it cannot be pressed and carries no side colour. `KeyTests` render it beside a resting key and read the pixels: the face clear, its top edge outlined, a side of the hairline's share of the ink exactly as tall as the resting key's, the same frame, face, baseline and centred legend, at both sizes in both looks. (Its frame was first aligned by its face; since 24 October 2026 layout centres the whole key.)
- **Keep's cards** lost two points of body to the taller key; the gap under the key went from 4 to 2 (the key's own side is part of it) so the file's sheet still fits, and every title on a card now stands on the middle of its key's face.
- **Guides and the cheat sheet** write a key as groups: `zo zc` is two sequences, `h j k l` four keys 8 apart, `esc`, `⌘K`, `⇧F` and `a…z` one key each.
- **`uppercased()`** on a bare keystroke is gone from flashes, the coach, the advisor, the config history, the launcher's verdicts, Keep's cards and the guides; the ones that remain are chords (⌥J, ⇧⌘V), VoiceOver's speech, or not keystrokes, and a source test lists each with its reason.
- **Chips that are read** (Ask's profile, the commands bar's source, the meeting's unit) are not keys and keep their own view; the drift test names them, and the list only shrinks.

Click hints: `hints-dense-{day,night}` lays 55 hints over a busy page (nav, sidebar, tabs, filters, ten rows, a rail), and `hints-dense-typed-{day,night}` shows it after the first letter. The build drew the hints both ways: two keys a hint were 52 wide and covered on average 58 percent of the width of the thing they point at (19 of 55 whole); one key is 27.5 wide, 40 percent, 6 of 55 whole. Neither made hints overlap each other. Hints are one key (see Decided in review).

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

- **A key held down by the pointer in the dark look** is hard to see: the side is close to the ground, so losing two points of it barely shows. Acceptable for now; noted for the slab and sound, which also mark a press.

## Decided in review

- **Click hints are one key** (23 October 2026): the owner wanted two keys for consistency, but the dense render showed one key reads far better. A hint is a name to type, not a key to find, and two keys hid 19 of 55 targets against 6. A hint draws its letters set tight in one key (`jk`), and the letters already typed go quiet inside it, in the quiet ink; a single letter is a square key. Everywhere else a sequence stays a key per keystroke.

- **More room** (23 October 2026): the first draft (22 tall, 6 each side) felt cramped; the key is 24 tall with 8 each side, and separate keys stand 8 apart.
- The large key, centred, and the four states are approved as drafted. (Pressed stopped being a state on 24 October 2026, below.)

- **Keys are centred as one object, and pressed is not a state** (24 October 2026). The owner approved both.
  - A key is laid out by its whole frame, face and side. Face-centring (the side hanging beneath, `alignmentRectInsets`) made keys look low, because the side is a solid, hard-edged band and the eye reads it as part of the key; a soft shadow is not, and layout still leaves a shadow out. The legend stays centred on the face. Words beside a key still stand on the key's legend baseline (`KeyWords`), so key and words move together. Beside a larger title, a key's letters now sit 1.5 points higher relative to the title than they did.
  - The night side colour is unchanged. Measured: the side is 5.0 in L* below the pane at night against 11.3 by day. It cannot go stronger without near-black, and a warmer side tested weaker.
  - `KeyState.pressed` is gone: it was never set in production, only in tests and the gallery. The pointer's press stays: `Keycaps.CapGroup` and `Key.fill` take the key to a 1-point side (a 4-point drop on a large key) while the mouse is down, with the frame unchanged. `Standing.pressed` stays for the things that are not keys (the room's buttons, popups, slab rows, the object surface, the walk's tiles). The gallery no longer draws a pressed row of keys.
