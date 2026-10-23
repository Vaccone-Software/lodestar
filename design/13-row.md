# 13 · The row

A line in a list. Every list Lodestar draws (the bars' results, Settings, menus, the coach's offer, the guides) is made of one of four rows, each with one height, one inset and one order of parts.

## What it is for

Lodestar is mostly lists, and today each list was laid out where it was drawn: ten row heights (48, 52, 36, 32, about 44, about 40, 24…), four title sizes, four icon sizes, gaps of 0, 2, 4 and 8, two kinds of dot, three detail separators, and a disabled row faded to 45% (its switch to 20%, the fades compounding). The eye reads a list by its rhythm, so a list should keep one. This contract names the four rows, what goes in each, and how a row says it cannot act now.

## Origin

- **Geometry** set the row at 48 with a 4-point side when chosen, 12 inside its pane, rounded at 10, and two-line rows at 52 so their face stays 48.
- **The key** said a Settings row's letter is a key, and a sequence is keys 4 apart.
- **The slab** made the chosen row a slab, its address keys resting and only the acting key lit.
- **The key** made a quiet key outline only its face; beside resting keys it read as a smaller key, so review made it a resting key left unfilled: the same face and side, the face outlined, the side in the hairline's tone (the key contract is amended).
- **The well** left "a Settings row that is off dims whole" to this contract.
- **The prototype** (`design/ceramic`) drew a dimmed row's title in quiet ink rather than fading it, and drew Settings' letters as keys in a 34-wide column, which stretched (geometry records the bug).

## Values

### Four rows

| Row        | Height                         | Where                                                        | Title                 | Lead              |
| ---------- | ------------------------------ | ------------------------------------------------------------ | --------------------- | ----------------- |
| **row**    | 48; 52 with a line beneath     | the launcher, Ask, the commands and web bars, the searcher, Settings' search results, the coach's offer | title (18) in a bar; label (16 medium) in a room or card | an app icon, 32 in a bar, 24 in a card |
| **setting** | at least 48; grows by its detail | a Settings group                                           | label (16 medium)     | its letter, a key |
| **line**   | 32                             | a menu: the input menu, Settings' popups, Keep's source list and card actions, the ⌘K card; the guides | body (16)  | a dot column, 16 wide, or a symbol, 16 |
| **legend** | 24, the key's height           | the cheat sheet, a footer                                    | body (16), or meta (13) in a footer | its keys |

A row is the thing, then its keys: what it is leads, how to reach it trails. A legend is the reverse, keys then what they do, as a footer reads ("esc Back"): its keys are the point. The guides list what each key opens (Safari `s`), so they are lines, the thing then its key, at the 32 pitch they keep today (a 24 key and 8 between); the cheat sheet lists what each gesture does, so it is a legend. That is why one leads with keys and the other trails with them, and both stay.

### Inside a row

| Part       | Value                                                                                           |
| ---------- | ----------------------------------------------------------------------------------------------- |
| inset      | words and icons 12 inside the row's edge                                                       |
| lead → words | 12                                                                                            |
| detail     | meta (13) in quiet ink, 2 below the title; parts joined by " · ", a path by " › "              |
| trailing   | 8 apart; centred on the title's first line; the acting key last                                 |
| keys       | a sequence 4 apart (the key); 8 after a title they follow                                       |
| words beside keys | on the key's face, never its whole frame: words at the legend's size (meta, 13) share the legend's baseline; larger words centre on the face (the face is the top 21 of the key's 24) |
| the dot    | one dot, 7 across, drawn: ink where it marks the current choice or your own setting, quiet where it marks a running app; 8 after the words it follows, or centred in a line's dot column |

### Between rows

- **Rows** in a pane stand 2 apart, so a slab's side never touches the next row; 12 from the pane's edge.
- **Settings** are a group's rows, joined by a hairline, no gap; the group insets them 12.
- **Lines** in a menu touch (0 apart), 8 inside the menu all round, so a chosen line's slab rounds at 22 − 8 = 14. A rule between line groups (Keep's destructive actions, "All apps") stands 8 above and below.
- **Legends** stand 8 apart.

### Words

**Names are cut at the tail; sentences wrap.** A title, an app, a file or a menu line is a name and ends in "…" when it does not fit. Detail in a row that holds a name is one line, cut at the tail. A setting's detail, a readout and a problem are sentences and wrap; the row grows. Today the ⌘K card cuts nothing and overflows.

### When a row cannot act

**Quiet, never faded.** A row that cannot act now (a setting that waits on another, an unavailable action, a disabled popup item) draws its title and detail in quiet ink, its keys quiet (the key's quiet state), and its control keeps its value, drawn quiet: an on switch's track is quiet ink instead of the accent, opaque, so what the setting will be is still shown. Nothing is drawn translucent: the 0.45 fade on a row and on Keep's missing-file card goes (material, rule 1: opaque). Quiet ink holds 4.5 : 1 on the pane at every level, so what cannot act is still read.

An **off** setting is not unavailable: it is a switch turned off, wearing the dot when off is not the default, and reads in full ink.

### The coach's whisper

The record under the coach's offer stays one line beside `lode ⌫` and "Not now", as it is today, and is cut at the tail only past the card's 540. Wrapping it was drawn and refused in review: the keys no longer lined up with the words, and the line it saved became empty card. The coach's records are written to fit (about 55 characters).

## Rules

1. **Four rows.** Every list line is a row, a setting, a line or a legend, at its height; no list lays out its own.
2. **One order.** A row leads with what it is and trails with its keys, the acting key last; a legend leads with its keys.
3. **One rhythm.** Rows 2 apart, settings by a hairline, lines touching, legends 8 apart.
4. **Trailing parts align to the first line, and words beside a key align to its face.** Today the coach's record, its "Not now" and every footer's words sit 1.5 to 2.5 points below their keys' letters, centred on the key's whole frame, side included.
5. **Names are cut at the tail; sentences wrap.** The coach's one-line record is the exception.
6. **Quiet, never faded.** Nothing in a row or a card is translucent.

## Enforcement

- `GeometryTests` holds the four heights (48 and 52, 48 minimum, 32, 24) and the gaps; the 36, the 32s and the 428 become named tokens.
- A gallery sweep finds every list line on every surface and checks it is one of the four, at its height, its words 12 in, its trailing parts centred on its first line (extending today's check beyond Settings and the bars).
- A test sets every name field's truncation to tail and every sentence field to wrap.
- `DesignDriftTests` fails an `alphaValue` below 1 or a layer opacity below 1 on a row, a card or a control (motion's fades excepted), and a dot drawn as a glyph.
- A pixel test holds the words beside a key on its legend's baseline (the coach, a footer, a Settings title's keys).
- A test holds every record the coach writes within its line at the card's widest, with the longest app names the gallery uses.

## Renders

- `foundation-row-*`: the four rows in each look, at rest, chosen, unable to act, with a long name and a long sentence.
- Before and after: the launcher, `settings-general-*`, `settings-keys-*`, `settings-search-*`, `inputmenu-*`, `choice-menu-open-*`, `keep-card-actions-*`, `keep-source-menu-*`, the ⌘K card, `coach-*`, `guide-*`, the cheat sheet, and a Settings page with a row that cannot act.
- The choice menu's render gets its pane from its rows (it now ends a row early, the harness's fixed 190 against 172).

## Status

Built 23 October 2026. Before it, every list laid out its own rows: ten heights (48, 52, 36, 32, about 44, about 40, 24), the input menu at 36 and the choice menu, Keep's lists and the guides at 32, gaps of 0, 2, 4, 8 and 12, a launcher dot set as a "●" glyph in an 8-point font and the others drawn, Settings' letter a grey word in a column sized by its widest letter, a Settings row 44 tall, a search result's address keys 12 apart and leading its title, a disabled row faded to 45% and its switch to 20% (about 20% together), Keep's missing-file card faded to 45%, and the coach's record, its "Not now" and every footer's words 1.5 to 2.5 points below their keys' letters.

Now `Row.swift` and the tokens in `Geometry.swift` hold the four rows. `ListRow` (a row: 48, 52 with its detail line) and `ListLine` (a line: 32) are `SlabRow`s that lay out their parts the one way; `LegendRow` is a legend on a 24-tall frame; a setting is `SettingsController.buildRow`, which now keeps to the same parts. `RowDot` is the one drawn dot, 7 across, in a 16-wide `DotColumn` in a line. `KeyWords` sets the words beside a key. The launcher, Ask, the commands bar, the coach's offer and Settings' search results are `ListRow`s; the input menu, a popup's choices, Keep's source list and card actions, the ⌘K card and the guides are `ListLine`s; the footers, a flash's way, the cheat sheet, the walk's key rows, a chain's header and a keymap are legends. The 36, the 32s, the 428 and 540 and the card icons' 24 and 6 are named tokens. Settings' dimmed row, `AccentSwitch`'s disabled opacity and Keep's missing-file card draw quiet: words and keys in the quiet ink, the switch's on track the quiet ink, opaque.

Measured by laying out and drawing every gallery surface in both looks and reading it back (`RowTests`, `GeometryTests`, `KeyTests`, `DesignDriftTests`):

- **Every list line is one of the four** (a sweep of every surface): a row is 48, or 52 with its detail; its icon 12 in and 32 or 24; its words 12 after the icon, or 12 in; its detail 2 under its title; its trailing parts 8 apart, the last 12 from the edge, each centred on the title's first line (a key by its face) and the lit key last; rows stand 2 apart. A line is 32, its words 12 in, 12 after its dot column or symbol, its parts 8 apart and on its line, touching its neighbours (or a rule's 16 between), its slab rounded at 14. A setting is at least 48 and its letters stand in one column with the titles after it. A legend is 24, its words 8 after its keys, and the cheat sheet's legends 8 apart.
- **Names are cut at the tail and sentences wrap**: every row's title and detail, every line's words, the words beside a key and every setting's title end in "…" on one line; every setting's detail, problem and readout wraps. Today's ⌘K card cut nothing and overflowed; its names now cut, and the card is never wider than a sentence's measure.
- **Words beside a key stand on its line**, read from the ink: the coach's record and "Not now", a footer's four words and a Settings title's capital are within half a point, day and night; before, the same measure put them 1 to 2.5 points low. Moving the shared baseline by one point makes the test fail.
- **The coach's records** (a bind, a shorten, a flatten, a retire, a route, a nudge, a meeting, a breath, at the longest app names the gallery uses and the biggest numbers) stand whole on one line at the card's widest.
- **The quiet key** is the resting key's frame, face, baseline and centred legend, its face clear with a hairline round it, its side the hairline's share of the ink and as tall as a resting key's (3, and 5 large), in both looks.
- **Nothing is translucent**: no alpha or layer opacity below 1 in the sources, and none on any view or layer of any surface; no dot glyph in the sources or on a surface. Each guard has a sample it is shown to catch.

**Decided in the build** (each worth the owner's eye):

- **Words at the legend's size stand on the baseline lowercase legends share**, not on the baseline of whichever key they follow: an x-height centred on the face is where mostly-lowercase words look centred, and it puts every word of a line, and `esc` and `lode` beside them, on one baseline. Following the nearest key put "Cancel" and "Send" a point apart in one footer. Larger words centre their capital height on the face.
- **A quiet key is `outlined` to the depth sweep**, neither flat (it has a side) nor standing up (it cannot be pressed and wears no side colour).
- **A key is aligned by its face**: the side hangs beneath it (`alignmentRectInsets`), so a row's trailing keys, a title's keys and the letter all stand with their faces on the title's first line, 1.5 points higher than when the whole frame was centred. A stack of keys is 21 tall to layout, so a legend (and a chain's header, a keymap, the walk's key rows) is put on a 24-tall frame, or the side would eat the gap beneath it.
- **A Settings result leads with its title and trails its address keys** (4 apart) and ⏎, as every row does; it led with the keys. The coach's offer likewise trails its quiet address beside the lit chord.
- **A guide's lines stand on the card's own inset**, not 12 inside a line of their own: a guide has no slab and nothing in it is chosen, so its words stay under the card's title. Its key is at least 12 from the name, where it was 24.
- **A flash's words stand 8 from the keys beside them**, as a footer's do (4 before).
- **The breath's record is the count** ("Messages and Mail travel together 12×"). The lift went to the report: it is not a count the hand can check, and two long app names left no room for it on the card's one line. It is a typed `Recommendation.record`, tested in Core.
- **Keep's source list stands its field and its lines 8 inside the menu**, and the rule between "All apps" and the rest takes 16 (8 above, 8 below). Keep's missing-file card is quiet: its words and key in the quiet ink, its sheets as they are (content).
- **A popup's disabled item keeps the quiet ink and never becomes the slab**; a dimmed Settings row's popup and fields show their value in the quiet ink.
- **`keep-missing-file-dimmed` is `keep-missing-file-quiet`**, and the new sheets are `foundation-row`, `settings-observations-waiting`, `optionscard-*` and `cheatsheet-two-sections`.

## Prototype lessons

- A dimmed row in quiet ink reads as waiting; a faded one reads as broken, and over a desktop as glass.
- A key column sized by a minimum width stretches; size it by its widest key.

## Decided in review

- A quiet key is a resting key left unfilled: the same face and side, its letter centred on its face. A single outline round face and side together was drawn first and read as a round chip (23 October 2026).
- Words beside a key align to its face: review found the coach's record and the footers sitting below their keys' letters (23 October 2026).
- The coach's record stays one line beside its keys; wrapping was refused (23 October 2026).
- The coach's offer leads with its apps' icons, 24 each, the second overlapping the first by 6, as today; the overlap and the size are tokens (`titleIconSize`), not `Grid.section` (23 October 2026).
- Approved 23 October 2026.
