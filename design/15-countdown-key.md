# 15 · The countdown key

The meeting's chip. The minutes until it starts stand on a large key beside its name. When the meeting is a minute away, that key lights, and pressing it joins the meeting.

## What it is for

The chip has one job: to say how long until the next meeting, and then to say "now" and take you in. The evidence says it does that job (DESIGN.md: 49 of 54 offered meetings joined, a median of 1.6 seconds before the start, dismiss used 3 times). This contract keeps the behaviour and redraws the chip in the language the other primitives built. The number becomes a key. The chip becomes a row. There is one lit key.

## Origin

- **Main draws a ticket stub.** On its leading edge, a face that fills with orange at the door and lights the pane's rim. Then a dashed perforation, the title and a meta line, and a lit `lode` `lode` group at the end. The unit is in capitals ("4 MIN", "MIN AGO"), and the key contract's drift list keeps it as "a chip that is read". Geometry found "min ago" drawn outside its frame. At the door, two things are lit: the stub and the chord.
- **The ceramic prototype** (`design/ceramic`, 3ef8ebb, 21 October 2026) replaced the stub with a countdown key, and the owner chose it over a ticket, a countdown in the pill and a ring. Its legends were "3m", "42s", "Now" and "4m ago". Before the door it had a flat outline; at the door it lit. Its `lode` `lode` stood resting at the end.
- **What the prototype predates.** The quiet key (a resting key left unfilled, contract 13), the large key's centred figure (contract 10), the row (contract 13) and words beside keys (`KeyWords`). This contract builds the prototype's idea from those.

## Values

### The chip is a row

The chip is a row with a detail line (contract 13), standing alone as its own surface: **52 tall**, rounded at the surface's 22, in the top-right of the screen as today, inset 20, movable as today, never the key window. Its width is set once for its whole life, as today.

| Part             | Where                                                             | What                                                          |
| ---------------- | ----------------------------------------------------------------- | ------------------------------------------------------------- |
| countdown key    | in the icon's place: 12 in, its face centred on the chip's middle | a large key, 36 tall (31 face + 5 side)                       |
| title            | 12 after the key                                                  | the meeting's name, title (18), cut at the tail               |
| detail           | 2 under the title                                                 | meta (13) quiet: "Zoom · 6 people"                            |
| join             | trailing, 12 from the edge, centred on the title's line by face   | `lode` `×2` resting, the word "Join" 8 after, on their baseline |

The large key stands where a bar's 32-point icon would. Its 31-point face is the icon's size, so the row's words fall where every bar's words fall. The key keeps its own rung, 8.4, as every key does: it is 8 from the chip's top and bottom and 12 from its side, so no radius could make it concentric.

### The legend

| When                                           | Legend   | Key   |
| ---------------------------------------------- | -------- | ----- |
| from the lead time to 60 s before (lead ≥ 1 min) | `4 min`  | quiet |
| the last minute                                | `45 sec` | lit   |
| from the start until it ends, you join or you dismiss | `Now`    | lit   |

- **The figure is the large key's**: 23 semibold, tabular. The unit is 13 semibold, 4 after the figure, on its baseline. The pair is centred on the face. `Now` is set at 23 semibold.
- **Minutes round down, seconds round up**, as `Meetings.phase` does today. The chip shows "1 min" until 60 s before, then "60 sec".
- **After the start the key keeps saying `Now`**, and the detail line says how late: "Started 4 min ago · Zoom · 6 people", in whole minutes. Main put "4 min ago" on the stub, the one legend that ran out of its frame. The key says what to do; the words say how long ago.
- **One width for the chip's life.** The key is as wide as the widest of `88 min`, `88 sec` and `Now` in its font, plus 8 each side. A lead time over 99 minutes measures `888 min`. A tick never moves a frame: the title, the detail and the chord stay where they are from the first draw to the last.

### Quiet, then lit

- **Before the door the key is quiet**: there if you want it, nothing asked of you yet. The legend is in quiet ink and the face is unfilled, standing on its side in the hairline's tone (contract 10).
- **At the door it lights**: an orange face on a darker orange side, ink on orange. It is the one lit thing on the chip. The pane's rim does not light. The chord does not light: it is a legend, telling the hand how to press the lit key, as a footer's keys do.
- **Clicking the countdown key joins.** So does clicking the chord, and so do `lode` `lode`, as today. `lode` `⌫` dismisses, and is not drawn, as today.

### Time and motion

- **The legend changes in place.** The text swaps on the frame it has, with no transition (Motion rule 2). The key lights at once (Motion: "a key lighting" is instant). There is no pulse, blink or count-up at the door.
- **Redraw on change only.** The chip redraws when the legend or the detail line changes: once a minute, then once a second in the last minute, as the 1 s timer does today.
- **Receding.** Before the door the chip recedes with every surface after 20 s (contract 6). At the door the lit key and the chip come back to full, and a lit key never recedes.

### What goes

The stub face and its notch, the perforation, the lit rim, capitals in the unit, "min ago" on the key, and the drift-list entry for "the meeting's unit". The prime card and the Meetings place in Settings are not changed.

## Rules

1. **The minutes are a key.** The number until the meeting is always on a large key. It is never a label, a chip or a stub.
2. **Quiet, then lit, never back.** Quiet before the door, lit from the door to the end. Nothing else on the chip lights.
3. **A tick moves no frame.** The chip's width and every part's place are set once.
4. **The key says what to do; the words say the rest.** `Now` stays on the key after the start; lateness, provider and people are in the detail line.
5. **Instant.** Legends swap and the key lights with no animation.
6. **The hand and the click do the same thing.** Clicking the key, clicking the chord and typing it all join.

## Enforcement

- **Model test:** the legend and quiet/lit for every phase. That covers lead 5 and 120, 61 s, 60 s, 1 s, 0, 89 s after and 40 minutes after. The detail reads "Started N min ago" only after the start.
- **Layout test:** the chip is 52. The key's face is 31, 12 in and centred on the chip within 0.5 pt. The title's leading edge is 12 after the key. Every frame is identical across all the legends of one occurrence, including a 120-minute lead.
- **Render test:**
  - Before the door, the countdown key reads `outlined` to the depth sweep and nothing is lit.
  - At the door, exactly one lit key: the countdown key. The pane's rim reads resting.
  - The chord is resting in every phase.
- **Type test:** the figure uses tabular figures (contract 2's test), and no legend on the chip is in capitals.
- **Motion drift test (contract 5):** covers `MeetingController`.
- **Accessibility:** one sentence, e.g. "Design review, in 4 minutes, Zoom, 6 people. Press lode twice to join." At the door: "Design review, now. …".

## Renders

`meeting/countdown-quiet` (4 min), `meeting/door-seconds` (45 s), `meeting/lit-now` (0), `meeting/past` (started 3 min ago), plus `meeting/long-title` (a name that is cut) and `meeting/receded` (quiet, after 20 s), in both looks.

## Status

Drafted 24 October 2026. Main draws the ticket stub.

## Decided in review
