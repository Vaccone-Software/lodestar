# 12 · The well

The place you put something. Wherever Lodestar takes words or a thing from you (a field, a note, a slot waiting for a clip), the place is a well: one step below the pane it sits in, one colour and a hairline edge, holding one caret.

## What it is for

A keyboard app is mostly places you type into, and the eye should find the place before the hand does. Material settled what a well is made of; this contract says where one is drawn, what shape it takes, and what lives in it: the words, the placeholder, the caret and the selection. Today the bars and Settings' value fields have a well; Settings' search, Keep's search and naming, and Keep's source list put their words straight on the pane, so the same act (type here) looks two ways. The caret comes in three colours and three widths.

## Origin

- **Material** (`design/04-material.md`) gave the well its matter: the pane darkened by 0.05 by day (`#E6DED6` in a clay pane, edge ink 14%) and 0.04 by night (`#14100D`, never below the ground, edge ink 12%), no side, no inner shadow. A step of 0.025 read flat, so it was doubled (22 October 2026).
- **Geometry** gave its corners: a control rounds at 8.4, and a field 12 inside a pane nests at 10. Geometry's Status left "a bar's field curve" waiting for this contract; the bars' wells were built with material, so that note is closed here.
- **DESIGN.md** called a well "what a field, a note box, a choice, a group's card or a read-only chip lies in". Material has since made a choice stand up and a chip or group flat, so the well is now only a place something goes.
- **The prototype** (`design/ceramic`) drew its well as ink at 5%, translucent, with a 44-tall bar well rounded at 12, and left Settings' fields in the system's bezel. Translucency read as a stain on clay, and the bezel wore the Mac's accent.

## Values

### The well

| Part     | Day look                    | Night look                               |
| -------- | --------------------------- | ---------------------------------------- |
| fill     | pane − 0.05 L (`#E6DED6`)   | pane − 0.04 L (`#14100D`), never below ground |
| edge     | ink 14%, 0.5 point          | ink 12%, 0.5 point                       |
| focused  | edge at ink 28%             | edge at ink 24%                          |
| side, shadow, glow | none              | none                                     |

**Focused.** The well the caret is in deepens its edge to twice its weight, at once. No ring, no accent, no fill change: the caret already says where the words will go, and the edge says it while the caret blinks off and when a room has two wells.

### Sizes and shapes

| Well            | Height                | Corners                         | Words inset | Words in      |
| --------------- | --------------------- | ------------------------------- | ----------- | ------------- |
| a bar's field   | 60                    | 10, nested 12 inside the pane   | 12          | field (23)    |
| a field         | 32                    | 8.4, the control rung           | 12          | body (16)     |
| a note          | at least 4 lines, 150 in Feedback | 8.4                  | 12          | body (16)     |
| a band's field  | 32, 4 inside its band | nested: the band's radius − 4   | 12          | the band's role |
| an empty slot   | the thing it waits for | the thing's own radius         | n/a         | meta (13), quiet |

Every height is on the size table; Keep's source list's 40-tall field becomes a field (32). A well that holds a key or a symbol at its leading edge (the launcher's mark, Settings' and Keep's `/`) holds it 12 in, and the words start 12 after it.

### What lives in it

- **Words:** ink, in the role the table gives. Never mono (type, rule: the voices are one family).
- **Placeholder:** quiet ink in the same role and size as the words, so typing replaces it in place. At least 4.5 : 1 on the well at every eye-comfort level (5.1 : 1 at full by day, 7.3 : 1 by night); the caret clears 3 : 1 in both (4.0 and 5.8).
- **Caret:** the readable accent, 1.5 wide, as tall as the line (20 at field size, 18 at body), rounded at half its width; where the accent would fall below 3 : 1 on the well it is ink. One caret everywhere a well is, drawn by Lodestar or by AppKit.
- **Selection:** one wash, ink at 30%, behind the words, in every well and in Keep's naming.
- **A well inside the slab** is the slab's look's well, as everything in it is (slab, rule 2).

### What is not a well

- **The draft.** It is a page you write on, not a field you fill; its insert bar (3 points) and block cursor belong to the draft's own modes and stay as they are, the 3 becoming a token.
- **The pill's echo** repeats what you typed elsewhere; nothing goes into it.
- **A value you can read but not change now** is flat: words on the pane, or a flat chip. A well is drawn only where something can go now; a Settings row that is off dims whole (the row, contract 13).
- **A choice, a switch, a group's card, a read-only chip:** stand up or flat, by material.

### Where it is

| Surface                                   | Today                            | Built                                   |
| ----------------------------------------- | -------------------------------- | --------------------------------------- |
| the launcher, Ask, the commands bar       | a bar's well                     | as it is; the focused edge               |
| Settings' value, number and add-bar fields | a field (`WellField`)           | as it is; the caret 1.5; the focused edge |
| Settings' search                          | words on the pane, a rule beneath | a field holding `/`; the rule goes      |
| Feedback's note and reply                 | wells; the note's caret ink, the reply's the system's, the note inset 10 | one caret, inset 12 |
| Keep's search and Bring's search          | words on the band                | a band's field                           |
| Keep's source list's filter               | words on the menu, 40 tall       | a field, 32                              |
| Keep's save-name band                     | the offered name on the band     | a band's field                           |
| naming a Keep card                        | the name on the card, washed 14% | a field over the name line, one selection |
| an empty keepsake                         | a well, the card's radius        | as it is                                 |
| a drop target                             | none exist                       | the first one is a well                  |

## Rules

1. **Something goes in, so it sinks.** Every place Lodestar takes words or a thing is a well, and nothing else is.
2. **One matter.** One fill and one edge per look, from the pane it sits in; no surface mixes its own.
3. **One caret, one selection.** The readable accent at 1.5, ink at 30%, in every well.
4. **Focus is the edge.** The focused well's edge deepens; no ring, glow or accent outline, and no system bezel or focus ring is ever drawn.
5. **The placeholder is quiet ink at the words' size**, holding 4.5 : 1 at every level.
6. **Shapes nest.** A well along a pane's or a band's edge rounds at the outer radius less its inset; a free well at the control rung; a slot at its thing's radius.

## Enforcement

- `CeramicTests.testTheWellIsOneStepBelowThePane` holds the fill and edge per look (exists); a new test holds the focused edge at twice the resting weight.
- A test holds the placeholder at 4.5 : 1 on the well at full, evening and bedtime, in both looks.
- A gallery test finds every editable text view on every surface and checks it sits in a `WellView` or `WellField`, unless it is the draft; and that each caret is the readable accent at 1.5.
- A gallery test checks every well's radius: nested where it meets an outer edge at its inset, 8.4 where free.
- `DesignDriftTests` fails a text field that leaves `isBezeled` on or draws a focus ring (today it catches only `bezelStyle`), and a literal field height off the size table.

## Renders

- `foundation-well-*`: the well sheet in each look at full, evening and bedtime: a bar's field, a field empty, placeholder, typed, selected and focused, a note, a band's field, an empty slot, and a well inside the slab.
- `settings-search-*`, `feedback-writing-*`, `keep-third-chosen-search-*`, `keep-source-menu-*`, a Keep save band and a card being named, before and after.

## Status

Planned. The bars, Settings' value fields, Feedback and the empty keepsake already draw the well's matter; the shapes, the caret, the focus edge and the surfaces without a well are not built.

## Prototype lessons

- A translucent well is a stain, not a place; the well is opaque, a step of the pane.
- A system bezel inside a room wears the Mac's accent and shape; every field draws its own well.
