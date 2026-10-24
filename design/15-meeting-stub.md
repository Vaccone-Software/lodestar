# 15 · The meeting stub

The meeting's chip is a ticket stub: a timer on its leading edge, the meeting beside it, and one action. It appears a few minutes before a meeting, alerts in the last minute, and steps back once the meeting has begun.

## What it is for

**The ideal stub** is a small thing that belongs to its moment. It is short, it reads as a timer at a glance, and it never looks like a headline feature. It does one job: to tell you how long until the meeting, to make "now" unmissable, and to take you in with one key. Its presence follows the meeting: normal while it approaches, loud in the last minute, quiet once it has begun. You may still join late, but it no longer asks.

The evidence says the shape works (DESIGN.md: 49 of 54 offered meetings joined, a median of 1.6 seconds before the start, dismiss used 3 times). This contract keeps the stub and makes it ideal; the primitives serve it.

## Origin

- **Main** draws the stub. On the leading edge is the count over its unit ("3" over "MIN"). A dashed perforation follows, then the title and a meta line ("Zoom · 6 people"), then a lit `lode` ×2. The stub fills orange at 60 s before and stays orange until the meeting ends. "MIN AGO" is wider than the stub and runs out of its frame (contract 3 found it).
- **A draft of this contract** (24 October 2026) put the minutes on a large key, made the chip a row, and dimmed the chord to keep one lit key. The owner rejected it, and the reasons are this contract's rules:
  - A key means a key press, and a timer is not pressed.
  - It grew longer for no stated reason.
  - It dimmed the main call to action.
  - It took the stub's character for a standard part's.

## Values

### The parts, as today

| Part        | What                                                                                  |
| ----------- | ------------------------------------------------------------------------------------- |
| the chip    | 48 tall, at the surface radius, top right of the screen, inset 20, movable, never the key window |
| the stub    | the leading segment: the count (figure, 18 semibold, tabular) over its unit (key, 13 semibold, capitals), centred |
| perforation | a dashed hairline between the stub and the body                                       |
| the body    | the title (quiet voice, 16) over the meta line (meta, 13, quiet), cut at the tail      |
| the action  | `lode` ×2, lit, trailing                                                               |

- **The stub's width** is set once for the chip's life, to the widest of its legends ("88" over "MIN", "88" over "SEC", "Now", "88" over "MIN AGO"), plus 8 each side, as today. Nothing runs out of its frame, and a tick moves nothing.
- **The chip's width** is set once, as today. The chip does not grow.

### Three phases

| Phase  | When                                           | Stub                                         | Count       | Chip                         |
| ------ | ---------------------------------------------- | -------------------------------------------- | ----------- | ---------------------------- |
| normal | from the lead time to 60 s before              | the chip's own surface, count in ink, unit in quiet ink | `4` `MIN`   | full, recedes after 20 s (contract 6) |
| alert  | from 60 s before to 90 s after the start       | orange, count and unit in ink on orange      | `45` `SEC`, then `Now` | full, never recedes          |
| quiet  | from 90 s after the start until the meeting ends | the chip's own surface, count and unit in quiet ink | `4` `MIN AGO` | receded at once              |

- **Alert is the one loud moment.** It begins with the last minute and ends 90 s into the meeting, the time it takes to join a meeting you meant to join.
- **Quiet is not gone.** The chip stays until the meeting ends, you join, or you dismiss, and joining still works. It just stops asking. Typing does not wake it: you may be typing in the meeting. A hover does.
- **The phases change at once** (contract 5): no fade from orange and no pulse.

### The action

- **`lode` ×2 is the call to action, so it is lit** in every phase. The orange stub and the lit key do different jobs: the stub says it is time, the key says what to press. The stub is not a key, so the key contract's one lit key holds.
- **Clicking the chord joins,** as typing it does. `lode` `⌫` dismisses, undrawn, as today. Clicking the stub does nothing: it is a timer.
- **The chord is centred as a whole key** (contract 10, amended 24 October 2026).

### What changes from main

1. **The quiet phase is new.** On main the stub stays orange until the meeting ends; now it steps back after 90 s.
2. **The stub is as wide as its widest legend,** so "MIN AGO" fits.
3. **The chord is centred as a whole key**, as every key now is.

Everything else is kept: the stub, the perforation, the body, the lit chord and the size.

## Rules

1. **The ideal first.** The stub is a timer and a ticket. A part from another contract is used only where it means the same thing here.
2. **The call to action is lit.** No rule dims it.
3. **One loud moment.** Orange on the stub only from 60 s before to 90 s after.
4. **A tick moves nothing.** Widths are set once.
5. **It does not grow.** Its size changes only with a reason written here.

## Enforcement

- **Model test.** The phase, the legend and the receding for:
  - leads 5 and 120;
  - 61, 60 and 1 s before;
  - 0, 89 and 91 s after;
  - 40 min after.
- **Layout test.** Every legend's ink stays inside the stub, "MIN AGO" included. The stub's and the chip's frames are identical across one occurrence's legends.
- **Render test.**
  - Normal and quiet: the stub has no orange.
  - Alert: the stub is orange.
  - The chord is lit in all three phases.
  - Quiet: the chip draws receded.
- **Motion drift test (contract 5).** Covers `MeetingController`.
- **Accessibility.** As today, and the quiet phase reads "started 4 minutes ago".

## Renders

`meeting/countdown-quiet` (normal, 4 min), `meeting/countdown-quiet-receded`, `meeting/door-seconds` (alert, 45 s), `meeting/lit-now` (alert, 0), `meeting/past` (quiet, 3 min after), plus `meeting/long-title`, in both looks.

## Status

Built 24 October 2026, replacing the countdown-key draft. Measured: the stub is 74 wide (the widest legend, "MIN AGO" at 13 semibold, 58, plus 8 each side, as on main) and the chip 273.5, the same in every phase and as on main. The stub is orange only from 60 s before to 90 s after the start; from 90 s after it is the chip's own surface and the chip draws receded at once (a hover brings it back, then the count of contract 6 begins again; a key does not). The chord is lit in every phase; `MeetingController.quietChordLit` exists only so a review can draw it resting.

## Decided in review
