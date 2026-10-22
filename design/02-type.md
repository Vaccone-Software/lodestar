# 02 · Type

One family, one scale, three weights. Every word Lodestar draws is set in the system's sans, at one of four sizes. There is no second face.

## What it is for

Type carries everything Lodestar says, and it should sound like one voice. Hierarchy comes from size and weight, never from a change of face. A second face is a second voice, and Lodestar has one.

## Origin

- **Three faces became one** (decided 21 October 2026). Lodestar had grown three families: the sans for most things, mono for fields, key letters, typed echoes and the draft, and a serif for the voice (the coach, Settings' sentences, the meeting's title). The canvas drew everything in one sans as a placeholder, and it read better than any pairing: the serif was a costume on a tool, and mono on a field said "terminal" where the field says "where to?".
- **Mono retires too** (22 October 2026). Mono was in the draft and the editor's lens only because they are vim-like, and vim's motions work on characters and words, not columns. What is written there is prose that lands in proportional apps, so it is set as it will be read.
- **The scale already existed.** Readability had cut nine drifting sizes to four (meta 13, body 16, title 18, input 23) with 13 as the floor. This contract keeps that scale and makes every font a role on it.

## Values

The family is the system font (SF Pro, with its optical sizes). Nothing is set in mono. Weights are regular, medium and semibold; bold appears only as semibold made heavier at night.

### The scale

| Size  | Points | Used for                                                    |
| ----- | ------ | ----------------------------------------------------------- |
| input | 23     | what you type into a bar: the launcher, Ask, Commands       |
| title | 18     | a bar's name, a room's title, a sentence the product speaks |
| body  | 16     | what a row, a card or a note says                           |
| meta  | 13     | captions, footers, details, key letters; the floor for text |

### The roles

| Role         | Size | Weight   | Face | Replaces                                                    |
| ------------ | ---- | -------- | ---- | ----------------------------------------------------------- |
| field        | 23   | regular  | sans | `inputFont` (mono), `stripInputFont` 19 mono                |
| voice        | 18   | regular  | sans | `voiceFont`, `settingsSentenceFont` (serif)                 |
| title        | 18   | regular  | sans | `titleFont`                                                 |
| room title   | 18   | semibold | sans | `roomTitleFont`                                             |
| body         | 16   | regular  | sans | `bodyFont`, `rowLabelFont`                                  |
| quiet voice  | 16   | regular  | sans | `coachVoiceFont`, `stubTitleFont` (serif)                   |
| typed        | 16   | semibold | sans | `typedFont` 17 mono                                         |
| emphasis     | 16   | semibold | sans | `stubWordFont`                                              |
| figure       | 18   | semibold | sans | `stubCountFont`                                             |
| large figure | 23   | semibold | sans | `KeyMark.peekFont` 24 mono                                  |
| meta         | 13   | regular  | sans | `secondaryFont`, `footerFont`, `stubDetailFont`, `metaMono` |
| name         | 13   | medium   | sans | `fileNameFont`                                              |
| label            | 16    | medium   | sans | a setting's title, a tile's name, a search hit |
| control          | 16    | regular  | sans | a popup's value, a button's title, a status word |
| heading          | 13    | semibold | sans | a group's header                             |
| key          | 13   | semibold | sans | `chipFont` (mono), `stubUnitFont`                           |
| draft            | 16    | regular  | sans | `readingMono`: the draft's text and the editor's lens |
| draft, marked    | 16    | semibold | sans | `readingMonoAccent`                          |

The strip's field comes up from 19 to the input size, so every bar's field is one size. A field inside a room (Settings' search, a value you type, Feedback's note) is body: it is part of a page, not a place you summon. `metaMono` becomes meta: a caption is a caption whatever it describes.

### Figures

A number that changes in place (a countdown, a count, a size) uses tabular figures, so it does not shift as it ticks. This is what mono used to do for the meeting's countdown and the peek, without the second face.

### Night

At night every role is one weight heavier: regular becomes medium, medium becomes semibold, semibold becomes bold. Light text on a dark ground reads thinner than the same weight dark on light, and the step brings it back. Size never changes with the look.

## Rules

1. **One family.** Every font is the system sans. No serif, no mono.
2. **The draft is prose.** The draft and the editor's lens are set in the body role like any other text, whatever app the words are going to. Vim's motions are unchanged; the block cursor is as wide as the letter it covers.
3. **On the scale.** Every size is 13, 16, 18 or 23. No text is below 13. A glyph used as a mark (the status dot) may be smaller, because it is not read.
4. **Three weights by day.** Regular to read, medium for a name or a label, semibold for what must be found first (a room's title, a key, a figure, a heading). A list of labels is medium, not semibold: when every row is the heaviest thing, nothing is. Hierarchy never comes from a second face, italics or letter-spacing, so the meeting's unit loses its tracking.
5. **One step heavier at night,** for every role, and it follows the look when it changes, not only when a surface is built.
6. **Tabular figures** for any number that changes in place.
7. **Sentence case** for every title and label Lodestar draws. Menu bar items follow macOS's title case, because they live in the system's menu.

## Enforcement

- A test reads every font the theme defines and fails on a serif or a mono face, on a size off the scale, or on a weight outside the three.
- A test builds surfaces in both looks and holds every label one weight heavier at night than by day, at the same size, including after the look changes while the surface is on screen.
- A test fails on a changing number drawn without tabular figures (the countdown, the peek, counts).

## Renders

`foundation-type-day`, `foundation-type-night`: every role, its size, weight and face, drawn from the theme. Then every surface, to judge the voice in use.

## Status

Not yet built. Main defines 24 fonts in three families: 8 in mono (`inputFont`, `stripInputFont`, `typedFont`, `readingMono`, `readingMonoAccent`, `metaMono`, `chipFont`, `KeyMark.peekFont`), 4 in serif (`voiceFont`, `settingsSentenceFont`, `coachVoiceFont`, `stubTitleFont`), and the rest in sans. Weights are the same by day and night, and the strip's field is 19 points, off the scale.

### The draft without mono

- **The block cursor** is a plate the width of the glyph under it, with the glyph cut out; past the end of a line it is the width of a space.
- **Columns** stop lining up, which only blockwise visual mode notices: it still selects by character column, and its edge is ragged. Four lines of prose rarely need it.
- **Counts and motions** (`3w`, `f,`, `ci"`) are unchanged: they act on characters and words.

## Prototype lessons

- **The night weight must follow the look.** The prototype applied the heavier weight only when a surface was built, so a surface on screen when the Mac turned dark kept its day weight until it was rebuilt.
- **Sans widths are fractional.** Mono had hidden it: a container sized to its text must round its width up, or the text truncates by a fraction of a point (the pill's frame did).
- **Read the sans voice on real surfaces.** The coach's line and Settings' sentences lost the serif's warmth and gained plainness; in renders they read as the product speaking rather than a quotation, which is the intent.

## Open

- Whether the typed echo (the letters the hand has typed, shown back in hints and select) is distinct enough as body semibold, or wants the orange it already has in some places.
