# 12 · The well

The place you put something. Wherever Lodestar takes words or a thing from you (a field, a note, a slot waiting for a clip), the place is a well: one step below the pane it sits in, one colour and a hairline edge, holding one caret.

## What it is for

A keyboard app is mostly places you type into, and the eye should find the place before the hand does. Material settled what a well is made of; this contract says where one is drawn, what shape it takes, and what lives in it: the words, the placeholder, the caret and the selection. Today the bars and Settings' value fields have a well; Settings' search, Keep's search and naming, and Keep's source list put their words straight on the pane, so the same act (type here) looks two ways. The caret comes in three colours and three widths.

## Origin

- **Material** (`design/04-material.md`) gave the well its matter: the pane darkened by 0.05 by day (`#E6DED6` in a clay pane, edge ink 14%) and 0.04 by night (`#14100D`, never below the ground, edge ink 12%), no side, no inner shadow. A step of 0.025 read flat, so it was doubled (22 October 2026).
- **Geometry** gave its corners: a control rounds at 8.4, and a field 12 inside a pane nested at 10. Review chose one radius for every input over nesting (below). Geometry's Status left "a bar's field curve" waiting for this contract; the bars' wells were built with material, so that note is closed here.
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

**Focused.** The well the caret is in deepens its edge to twice its weight, at once. No ring, no accent, no fill change: the caret says where in the words, the edge says which well, which matters when a room has two.

### Sizes and shapes

| Well            | Height                | Corners                         | Words inset | Words in      |
| --------------- | --------------------- | ------------------------------- | ----------- | ------------- |
| a bar's field   | 60                    | 8.4                             | 12          | field (23)    |
| a field         | 32                    | 8.4, the control rung           | 12          | body (16)     |
| a note          | at least 4 lines, 150 in Feedback | 8.4                  | 12          | body (16)     |
| a band's field  | 32, 4 inside its band | 8.4; the band rounds at 12.4    | 12          | the band's role |
| an empty slot   | the thing it waits for | the thing's own radius         | n/a         | meta (13), quiet |

Every height is on the size table; Keep's source list's 40-tall field becomes a field (32). A well that holds a key or a symbol at its leading edge (the launcher's mark, Settings' and Keep's `/`) holds it 12 in, and the words start 12 after it.

### What lives in it

- **Words:** ink, in the role the table gives. Never mono (type, rule: the voices are one family).
- **Placeholder:** quiet ink in the same role and size as the words, so typing replaces it in place. At least 4.5 : 1 on the well at every eye-comfort level (5.1 : 1 at full by day, 7.3 : 1 by night); the caret clears 3 : 1 in both (4.0 and 5.8).
- **Caret:** the readable accent, 1.5 wide, as tall as the line (20 at field size, 18 at body), rounded at half its width, and still: it never blinks, so it is always where the eye looks for it. Where the accent would fall below 3 : 1 on the well it is ink. One caret everywhere a well is, drawn by Lodestar or by AppKit.
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
3. **One caret, one selection.** The readable accent at 1.5, never blinking; ink at 30%; in every well.
4. **Focus is the edge, and the caret holds still.** The focused well's edge deepens; no ring, glow or accent outline, and no system bezel or focus ring is ever drawn.
5. **The placeholder is quiet ink at the words' size**, holding 4.5 : 1 at every level.
6. **One radius for every input.** A field, a note and a bar's field round at 8.4, wherever they sit. A band that holds only a field takes its corners from the field (8.4 + its 4-point inset = 12.4), so the gap stays even; an empty slot keeps its thing's radius.

## Enforcement

- `CeramicTests.testTheWellIsOneStepBelowThePane` holds the fill and edge per look (exists); a new test holds the focused edge at twice the resting weight.
- A test holds the placeholder at 4.5 : 1 on the well at full, evening and bedtime, in both looks.
- A gallery test finds every editable text view on every surface and checks it sits in a `WellView` or `WellField`, unless it is the draft; and that each caret is the readable accent at 1.5.
- A gallery test checks every input well rounds at 8.4 and every field band at 12.4.
- `DesignDriftTests` fails a text field that leaves `isBezeled` on or draws a focus ring (today it catches only `bezelStyle`), and a literal field height off the size table.

## Renders

- `foundation-well-*`: the well sheet in each look at full, evening and bedtime: a bar's field, a field empty, placeholder, typed, selected and focused, a note, a band's field, an empty slot, and a well inside the slab.
- `settings-search-*`, `feedback-writing-*`, `keep-third-chosen-search-*`, `keep-source-menu-*`, a Keep save band and a card being named, before and after.

## Status

Built 23 October 2026. Before it, the bars' wells rounded at 10 (a row's nested radius) and Settings' fields at 8.4; Settings' search, Keep's search and Bring's, Keep's save band and the source list's filter put their words straight on the pane (the filter in a 40-tall line), and a Keep card being named washed its name at 14%. The caret came in three colours and widths (the bars' and Settings' fields in the accent at the system's width, Feedback's note in ink, its reply's in the system's accent), Feedback's note was inset 10, Settings' search field kept its bezel on (`isBezeled` was never turned off), and no well deepened its edge for focus.

Now `WellText` is the one text view words are edited in: every Lodestar field's cell (`InputCell`, behind `InputField` and `WellField`) hands back one `WellText` as its field editor, and Feedback's note (`NoteWell`) is one. It sets the system's caret clear and places a `CaretMark` (1.5 wide, the readable accent judged on the well, ink below 3 : 1, rounded at half its width, 20 tall beside the field role's words and 18 beside the body's) at the insertion point; it never animates, so it never blinks. The selection is ink at 30% (`BarTheme.wash`) in every field editor and in Keep's naming. `WellView`, `WellField` and `RoomField` watch the field they surround (`hold`) and draw the edge at twice its share, at once, while the caret is in it (`BarTheme.wellEdgeFocused`); Keep's drawn fields are always focused except the band while the list of sources is open. The bars' wells, Settings' fields and search, Feedback's note and reply and Keep's field bands all round at 8.4, and Keep's bands at 12.4 (`BarTheme.bandRadius`, 8.4 + the 4-point `bandInset`), 40 tall (`bandHeight`, a field and its inset). The source list's filter is a field of 32; a card being named is a well beside its key, in the slab's look, with no caret while its offered name stands selected. The draft keeps its 3-point bar as `BarTheme.draftBarWidth`.

Measured by drawing every gallery surface and reading the pixels back (`WellTests`, beside `PaneTests.testTheFocusedWellsEdgeIsTwiceTheRestingWeightInEachLook`):

- **The caret** in every real field of the well sheet is 3 device pixels of the accent at 2x (1.5 points), at the insertion point, and no other saturated pixel stands in the field's row (the system's caret is gone); held for two blink periods (four samples 0.45 s apart) it is whole every time and nothing animates it.
- **The edge** is the ink at 14% (day) and 12% (night) at rest, and 28% and 24% with the caret in it, read off the one row of pixels the half-point edge is.
- **Every editable text view** on every gallery surface (the launcher, Ask, Commands, Settings' fields and search, Feedback's note and reply) sits in a well, draws no bezel, border or focus ring, is edited in the one editor and holds the one caret; the draft's text view is not editable and is not a field.
- **Every input well** rounds at 8.4, every field band at 12.4, every field is 32 tall and every band 40, with its field 4 inside it.

| Placeholder, quiet ink on the well | full | evening (88%) | bedtime (80%) |
| ---------------------------------- | ---- | ------------- | ------------- |
| day | 5.16 | 4.58 | 4.51 |
| night | 7.26 | 6.50 | 5.99 |

The caret's accent on the well: 3.99, 3.88 and 3.88 by day, 5.77, 5.19 and 4.89 by night, over its floor of 3. The day placeholder at bedtime is the tightest, 4.51 against 4.5.

**Decided in the build** (each worth the owner's eye):

- **A selection has no caret,** in a real field or a drawn one: the wash says where typing lands. Keep's offered name stands selected with the wash and no caret; once it is edited the caret stands at its end. Before, it drew both.
- **Keep's band is 40 tall, not 44.** The contract's 32 field and 4 inset give 40; the cards below moved up by 4.
- **A name too long for its well scrolls as a field's does:** the end, where the caret is, stays in view (the head is cut); the selected offered name shows its head. A name has about 100 points on a card 150 wide, since the well takes 12 each side.
- **While the list of sources is open its field has the caret and the band over it rests,** its edge at the resting weight and no caret: one caret on a surface.
- **The caret and the focused edge are shown while the window has the keys, and in a window nobody can see.** AppKit draws a caret only in the key window, and Settings' window cannot take the keys while the app is not active, which is how every render is drawn; a window that is not on a display is drawn as if it had them. A visible window without the keys shows neither.
- **A clip named before it has a place** is named on the band's card, the slab, and its card in the row is no second slab.
- **The pictures are drawn with the keys:** a panel that is typed in is brought key for the bitmap, off every display, and put away (`GalleryRender.holdingKeys`).

## Main lessons

- **The system's caret has a width of its own.** macOS 14 and after draw it as `NSTextInsertionIndicator`, a view in a private overlay inside the field, 1 point wide and blinking, with no property for either; `insertionPointColor` clear hides it, and the one caret is drawn where the insertion point is. The classic path (`_useTextInsertionIndicator` false) draws a 1-point view in the same overlay, so it does not help.
- **A field editor shows the Mac's grey in a window without the keys.** An unemphasized selection ignores `selectedTextAttributes`, so a picture of a selection is taken with the keys.
- **A window can take the keys only if it may.** An activating panel (Settings) cannot while the app is not active; the harness keeps such a window away and draws it as one nobody can see.
- **Anchors are alignment rects.** A borderless text field's frame is 2 points wider each side than its anchors, and its words start at the anchor: a test of "12 in" reads `alignmentRect`, not the frame.
- **`firstRect(forCharacterRange:)` needs a screen.** In a window no display shows it answers nothing; the insertion point is found from the text layout itself.

## Prototype lessons

- A translucent well is a stain, not a place; the well is opaque, a step of the pane.
- A system bezel inside a room wears the Mac's accent and shape; every field draws its own well.

## Decided in review

- The caret does not blink (23 October 2026).
- Focus is the edge doubling, not the caret alone (23 October 2026).
- One radius for every input, 8.4, over nesting each in what holds it: nesting made the launcher's field 10, Keep's a capsule and Settings' 8.4, three shapes for one act. Keep's search and save bands round at 12.4 instead of as capsules (23 October 2026).
