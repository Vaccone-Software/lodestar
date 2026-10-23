# 11 · The slab

The chosen thing. In every list, menu and strip, the one thing a key would act on is a slab of the other look's ground, standing on a side, with everything inside it in the other look.

## What it is for

Lodestar is driven from the keyboard, so there is always one thing the next ⏎ will act on, and the eye has to find it at once. Today the chosen row rises onto the key step: a pale face on a pale pane, told apart by a 4-point side and a rim, which reads only to good eyes in good light. An inverted slab reads to everyone at a glance, in both looks, and it is neutral, so the orange keeps its one job: marking where the hand goes next.

## Origin

- **Decided with Ceramic** (20 October 2026): "each look is the other's selection." A raised step, an ink ring and a leading rule were drawn beside the slab on the canvas "Primitives and website", and only the slab read at a glance to every eye.
- **Built on the foundations:** the slab colours from colour (`#2A221D` on `#120D0A` by day, `#F1E8DF` on `#ADA093` by night), the row's side (4) and the nested radius from geometry and material, instant change from motion, the dim from eye comfort.
- **The prototype** (`design/ceramic`) built a slab and taught three things: the side hung below its row, where the next row drew over it; dots and chips baked in one look stayed in it when their row flipped to the other; and lighting every key on the chosen row made three orange keys where one was meant.

## Values

### The slab

| Part      | Day look                           | Night look                     |
| --------- | ---------------------------------- | ------------------------------ |
| face      | slab `#2A221D` (espresso's family) | slab `#F1E8DF` (clay's family) |
| side      | slab side `#120D0A`, 4 points      | slab side `#ADA093`, 4 points  |
| rim       | the night's rim (ink at 10%)       | clay's rim (the key step)      |
| edge      | the night's hairline               | clay's hairline                |
| inside it | the night look, whole              | the day look, whole            |

**Shape.** The slab is the row's own frame: its face is the frame less the side, so nothing hangs below it (geometry, rule 6). Its corners are the row's nested radius, the same as today's raised row, so a slab in a pane keeps an even gap from the pane's corners. A card that becomes the slab keeps the card's radius.

**Size.** The slab is exactly the thing that is chosen, never wider: a row in a bar spans the row, a card is the card, a tile is the tile, a stop is the stop.

### Inside the slab

Everything in the slab is drawn in the other look, resolved in the slab's own look at draw time, never baked:

- **Words:** the other look's ink and quiet ink (13.2 : 1 and 6.0 : 1 on the day slab, 14.5 : 1 and 5.7 : 1 on the night slab).
- **Keys:** the other look's keys: face, side and hairline. A key on the day slab is a night key; on the night slab a clay key.
- **Dots, chips, rules and badges:** the other look's.
- **Pictures, app icons and previews:** as they are (material, rule 7).

### What lights on the slab

**One key lights: the key that acts on the chosen thing.** In a bar that is ⏎; in Keep, the key that pastes; in a menu, ⏎. The address keys on the slab (`e` `p`, a Settings row's letter) rest in the slab's look: the slab already says which thing is chosen, so the address needn't shout too. If nothing on the slab acts, nothing lights; the slab alone marks the choice.

**The orange on the slab** is the slab's look's orange: night's `#FA5617` with ink letters on the day slab, clay's `#C83500` with clay letters on the night slab (4.38 : 1 as a fill, its letter 5.01 : 1).

### Where it is

Every chosen thing in Lodestar's own lists, menus and strips:

| Surface                                                                   | Today                               |
| ------------------------------------------------------------------------- | ----------------------------------- |
| the launcher, Ask, the commands and web bars                              | raised row, every key lit           |
| the searcher                                                              | raised row                          |
| Keep's chosen card (the newest, until a key moves it) and its action menu | lifted card; raised line            |
| the input menu, the options card, Settings popups                         | raised row or system-like highlight |
| Settings' chosen row and the landing step                                 | raised step                         |
| the walk's chosen tile                                                    | raised tile                         |
| the coach's offer row                                                     | raised row                          |
| a row of stops' current value (contract 14)                               | not built yet                       |

Menus drawn by macOS itself (the menu bar's menu) keep the system's highlight; Lodestar does not draw them.

### Behaviour

- **One slab per surface.** Choosing another thing moves the slab there.
- **Instant.** The slab moves, appears and leaves at once, with no slide and no fade (motion contract).
- **Follows the choice, however it was made.** Keys move it; where the pointer chooses today (a menu under the pointer), the pointer moves it. Hover alone never adds a second slab.
- **Pressed.** Clicking the slab presses it: its side collapses to 1 point at once, the face moving down by what it gave up. Pressing the lit key presses that key, not the slab.
- **Eye comfort.** The slab dims with its look's level like everything else. The floors hold on it at every level: ink 7 : 1, quiet ink 4.5 : 1, the orange as a fill 3 : 1.

## Rules

1. **Selection is the slab.** No raised step, ring, rule, tint or bold marks a chosen thing anywhere Lodestar draws.
2. **The other look, whole.** Everything inside the slab is drawn in the other look, resolved when drawn.
3. **One lit key, the one that acts.** Nothing else on the slab is orange.
4. **Inside its frame.** The side is within the thing's frame; nothing hangs below it.
5. **One per surface, and instant.**
6. **Content is untouched.** Pictures and icons on the slab are drawn as they are.

## Enforcement

- A drift test fails on a chosen state drawn any other way: `RaisedRow`'s key-step face, a selection tint, an inline highlight colour, a bold-for-chosen.
- Gallery tests, for every surface with a chosen thing, in both looks:
  - the chosen thing's face is the slab colour and its side is 4 points inside its frame;
  - every word on it meets the other look's floors (by measured pixels);
  - exactly one lit key on the slab, and it is the acting key, or none;
  - no colour from the surrounding look survives inside the slab (no clay-quiet ink on the day slab, no espresso key on the night slab).
- The floors on the slab hold at evening and bedtime levels.

## Renders

`foundation-slab-{day,night}`: a pane with three rows, the middle one the slab, holding words, quiet words, an icon, resting keys, the lit ⏎, a dot and a chip; a card as the slab; a pressed slab. Then every surface in the table above, chosen.

## Status

Not yet built. Main marks the chosen row by raising it onto the key step (`RaisedRow` in Ceramic.swift) and lights every key on it (address and ⏎). The launcher, Ask, the commands, web and searcher bars, Keep's action menu, the input menu, the coach's offer row and Settings' landing step use `RaisedRow`. Keep's chosen card, Settings' chosen row and the walk's tiles mark the choice in their own ways.

## Prototype lessons

- **Reserve what you draw.** The prototype's slab stood on a side that hung below its row, where the next row drew over it; the side belongs inside the frame.
- **Resolve in the slab's look.** Dots and chips baked as CGColor kept the surrounding look when their row flipped; everything in the slab resolves under the slab's appearance in the draw pass.
- **One lit key.** Lighting the address with ⏎ made three orange keys on one row.

## Open

- **Keep's chosen card as a whole slab.** A card is far larger than a row; a full espresso card by day is the strongest mark Lodestar would draw. Shown on the review page beside a card that keeps its clay face and wears the slab only as its key strip; decided there.
