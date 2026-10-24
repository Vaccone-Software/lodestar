# 14 · Stops

A setting with an order. Every value is shown as a key, side by side, smallest to largest; the current one is the slab. Its row's letter gives the hand the keys: a digit chooses a stop, `h` and `l` step.

## What it is for

A popup hides its values until it is opened, and a menu says nothing about how its values relate. When a setting's values are a scale (how much model, how big, how long), the scale is the information: seeing "Automatic · Apple · Standard · Full · Max" in a line says what a popup's "Automatic · Full" cannot, that there is more above and less below, and what this Mac can run. Stops show the whole scale and where the setting stands on it, and they let the hand move along it without opening anything.

Reach for stops only when the values are **a closed set of two to eight with a natural order**. A free quantity (a size in MB, minutes of lead time) stays a number in a well (contract 12); a set with no order (a microphone, a language, the lode key) stays a popup.

## Origin

- **DESIGN.md (October 2026):** "A setting with an order is a row of stops: every value shown as a key, the current one the slab, 1–8 choosing directly and h/l stepping." A ceramic dial was drawn first and refused (handsome at a row's size and hard to use); a stepper, a notched rail, a ticker and cycling on the row's own key were drawn too.
- **The prototype** (`design/ceramic`, commit 860964b) built stops on Speak's model: keys 26 tall and 6 apart under the title, the current one a slab, a caption under the keys, a hint line while the row held the keys. It taught that digits must stay places until a row asks for them (the row's letter hands them over), that a stop this Mac cannot run must still be shown, and that stepping must skip it.
- **Built on:** the key (contract 10) for every stop, the slab (11) for the current one, the row (13) for where they stand, the quiet key for a stop that cannot be chosen.

## Values

### Where stops are used

| Page  | Setting | Stops                                         | Today                     |
| ----- | ------- | --------------------------------------------- | ------------------------- |
| Speak | Model   | `Automatic` `Apple` `Standard` `Full` `Max`   | a popup, "Automatic · Full" |
| Write | Model   | `Automatic` `Spelling` `Minimal` `Standard` `Full` | a popup                |

Nothing else in Settings has a closed order: the number fields are free quantities, and Updates, Active display, Units, Microphone, Spelling, Fallback profile, Lode key and Dominant hand have no order. A setting that gains one later uses stops.

### A stop

| Part     | Value                                                                                         |
| -------- | --------------------------------------------------------------------------------------------- |
| a stop   | a resting key (contract 10): 24 tall, 21 face + 3 side, its legend the value's short name, 8 each side |
| between  | 8 (keys that are not one sequence)                                                            |
| current  | the slab: the same face (21, as wide as the key, the key's radius 8.4) on the slab's 4-point side, its legend in the slab's ink |
| cannot be chosen | a quiet key: the resting key left unfilled (contract 10), legend in quiet ink            |
| count    | 2 to 8                                                                                        |

**The current stop does not move anything.** Its face is the key's face, so choosing another stop changes which face is the slab and nothing else: no stop shifts, no width changes. Stops align by their faces (contract 13), so the slab's extra point of side hangs below the line, as a pressed key's does not.

### Where they stand

- **On their own line under the setting's words,** 12 below the last line of the detail, starting at the title's leading edge. A row of five word-keys is about 320 wide; beside the title it would squeeze the detail to a third of the row, so it stands under it, as the scale it is.
- **The caption** says what the current stop means, in meta quiet, 12 after the last stop, on the keys' line (words beside a key, contract 13): "Full · about 20 GB on this Mac", "Automatic · Full". It is cut at the tail if it would reach the row's trailing inset.
- **The row grows** by the stops' line: 12 + 24. It is a setting (contract 13): at least 48, and it grows.

### When the row holds the keys

Pressing the row's letter gives it the keys. While it holds them:

- **The letter stays down:** its key is drawn pressed (side 1, face down by the rest), the one key on the page that is. Pressing the letter again, `esc` or `⏎` lets go, and the key comes up.
- **The caption gives way to the legend:** `1`–`5` choose · `h` `l` step, on the same line, meta words beside keys (a legend, contract 13). The digits shown run to the number of stops.
- **Keys:**
  - a digit `1`–`8` chooses that stop and writes it at once; a digit with no stop, or a stop that cannot be chosen, does nothing;
  - `h` or `←` steps to the previous stop that can be chosen, `l` or `→` to the next, writing at once; at either end nothing happens (no wrap);
  - `0` and `9` do nothing; every digit belongs to the stops while the row holds the keys, so a slip never moves the page;
  - any other key lets go and then does what it does on the page (another row's letter, `/`, a place's digit after `esc`).
- **Nothing is lit.** A stop writes the moment it is chosen; there is no ⏎ to confirm, so no key is "the one to press next".

### Mouse

A click on a stop writes it. It does not give the row the keys.

### When stops cannot act

- **A stop this Mac cannot run** is a quiet key; the others rest. The caption says why when the current stop is the reason ("Max needs 64 GB").
- **A row that cannot act** (dimmed by another setting) keeps its value, drawn quiet (contract 13): every stop is a quiet key, and the current one is a quiet slab: the slab's shape in the hairline's tone, its legend in quiet ink, opaque. The letter does not give the keys.

### On a slab

When the stops' row is itself the slab (a search landing, contract 11), its stops are in the slab's look, and the current stop is the other look's slab again: a clay slab on the night slab. The current stop is a value, not where the next key acts, so it is the one slab that stands while another thing is chosen.

## Rules

1. **Only for an order.** Two to eight values with a natural order; never a nominal set, never a free quantity.
2. **The whole scale, always.** Every value is shown, including the ones this Mac cannot run.
3. **Smallest to largest, left to right,** with Automatic first where there is one.
4. **Choosing moves only the slab.** No stop changes size or place.
5. **Digits are places until a row asks for them.** Only the row's letter hands the digits and `h`/`l` to the stops; letting go hands them back.
6. **Writing is instant.** A stop chosen by key or click is the setting at once; there is no confirm step and no animation.
7. **Accessible as a choice:** the stops are a radio group named by the row's title, its value the current stop's legend.

## Enforcement

- A model test: stops are only built for a control with 2–8 ordered options; `stop(forKey:)` and `step(from:by:)` skip unavailable stops and never wrap.
- A layout test: every stop is 24 tall, faces aligned within 0.5 pt, 8 apart; the current stop's face equals its key's face in width and place in every state; choosing another stop moves no frame.
- A key-routing test: before the letter, `3` goes to place 3; after it, `3` chooses stop 3 and the page stays; `9` does nothing; `l` at the end does nothing; `h` skips a stop that cannot be chosen; `esc` lets go and `3` is a place again; another row's letter lets go and activates that row.
- A render test: the held letter is the only pressed key on the page; nothing is lit while the row holds the keys.
- The row-alpha drift guard (contract 13) covers a dimmed row's stops.
- Accessibility: the group's role, name and value.

## Renders

`settings-speak-*` and `settings-write-*` at rest; `settings-speak-stops-held-*` (the row holding the keys); `settings-speak-stops-small-mac-*` (Max and Full quiet); `settings-write-stops-dimmed-*` (the row that cannot act); a stops sheet in `foundation-row-*` with every state, day and night.

## Status

Drafted 23 October 2026. Main shows both Model settings as popups.

## Decided in review
