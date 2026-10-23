# 13 · The row

A line in a list. Every list Lodestar draws (the bars' results, Settings, menus, the coach's offer, the guides) is made of one of four rows, each with one height, one inset and one order of parts.

## What it is for

Lodestar is mostly lists, and today each list was laid out where it was drawn: ten row heights (48, 52, 36, 32, about 44, about 40, 24…), four title sizes, four icon sizes, gaps of 0, 2, 4 and 8, two kinds of dot, three detail separators, and a disabled row faded to 45% (its switch to 20%, the fades compounding). The eye reads a list by its rhythm, so a list should keep one. This contract names the four rows, what goes in each, and how a row says it cannot act now.

## Origin

- **Geometry** set the row at 48 with a 4-point side when chosen, 12 inside its pane, rounded at 10, and two-line rows at 52 so their face stays 48.
- **The key** said a Settings row's letter is a key, and a sequence is keys 4 apart.
- **The slab** made the chosen row a slab, its address keys resting and only the acting key lit.
- **The key** made a quiet key outline only its face; beside resting keys it read as a smaller key, so review made it a resting key drawn in hairlines, face and side (the key contract is amended).
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

**Quiet, never faded.** A row that cannot act now (a setting that waits on another, an unavailable action, a disabled popup item) draws its title and detail in quiet ink, its keys quiet (flat, the key's quiet state), and its control in the control's own off state. Nothing is drawn translucent: the 0.45 fade on a row and on Keep's missing-file card goes (material, rule 1: opaque). Quiet ink holds 4.5 : 1 on the pane at every level, so what cannot act is still read.

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

Planned.

## Prototype lessons

- A dimmed row in quiet ink reads as waiting; a faded one reads as broken, and over a desktop as glass.
- A key column sized by a minimum width stretches; size it by its widest key.

## Decided in review

- A quiet key is a resting key drawn in hairlines: the same shape, face and side, its letter centred on its face (23 October 2026).
- Words beside a key align to its face: review found the coach's record and the footers sitting below their keys' letters (23 October 2026).
- The coach's record stays one line beside its keys; wrapping was refused (23 October 2026).
