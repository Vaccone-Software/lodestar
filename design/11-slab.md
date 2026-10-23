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

Built 23 October 2026. Before it, main marked the chosen row by raising it onto the key step (`RaisedRow` in Ceramic.swift) and lit every key on it (address and ⏎). The launcher, Ask, the commands, web and searcher bars, Keep's source list, the input menu, the coach's offer row and Settings' landing step used `RaisedRow`; Keep's card being acted on stood on the key step, the newest card had only its key lit, the walk's chosen tile was ringed in the accent, and Settings' popups drew the key-step row in a draw pass.

Now `Slab.swift` holds the primitive. `SlabRow` replaces `RaisedRow`; a chosen `ObjectSurface` is a Keep card, `TileColumn` the walk's tile, `ChoiceMenuItemView` a Settings popup's row and `LandingStep` the step behind a Settings row. The slab's look is an appearance: a chosen view takes the opposite of its host's (`Slab.Flip` holds it there and follows the host when the Mac turns), every colour inside resolves in it at draw time, and the slab's own face is `BarTheme.slabFill`, which asks the opposite look for its slab step. `BarTheme.accent` and `onAccent` now resolve in the look of the view that draws them, so a lit key on a slab is that look's orange.

Measured by rendering every gallery surface in both looks at full, evening and bedtime levels and reading the pixels back (`SlabTests`):

- **The face** is the slab step (day `#2A221D`, night `#F1E8DF`) and its side shows 4 points of `#120D0A` (`#ADA093`), inside the frame: nothing below the frame is the side's colour. Pressed, the side is 1 point and the face, and what is on it, is 3 lower.
- **One slab per surface** on every surface of the gallery: launcher, Ask, commands, Keep (the card, or the source list's line), the coach's offer, the walk's tile, Settings' hit and landing, a Settings popup, the input menu.
- **Words** reach their floors on the slab by measured pixel: every ink word 7 : 1, every quiet word 4.5 : 1, in both looks and at every level.
- **No colour of the surrounding look survives:** every view inside a slab resolves in the other look; no word or layer inside holds a step of the look around it that the slab's own look does not also hold.
- **One lit key at most, and it acts:** ⏎ in a bar's row and in a Settings result, `lode` (×2) on the coach's offer, the key that pastes on Keep's chosen card (and none while a menu is open). The address keys rest.

| Slab | ink | quiet ink | orange as a fill | letter on it |
| ---- | --- | --------- | ---------------- | ------------ |
| day, full | 13.18 | 5.99 | 4.76 | 5.36 |
| day, evening (88%) | 11.68 | 5.36 | 4.28 | 4.82 |
| day, bedtime (80%) | 10.69 | 4.94 | 4.03 | 4.54 |
| night, full | 14.51 | 5.65 | 4.38 | 5.01 |
| night, evening (88%) | 12.87 | 5.01 | 4.25 | 4.86 |
| night, bedtime (80%) | 11.77 | 4.93 | 4.25 | 4.86 |

**Eye comfort inside the slab.** Each side of the slab keeps its own look's rule at the one level, and nothing was added for the slab. The slab's face is the slab step of the look around it, dimmed by that look's rule (the light look's slab is dark and is not dimmed; the dark look's slab is clay's family and dims with the night's bright things). What stands on it is the other look at the same level: on the day slab, the night's ink and quiet ink, dimmed by the night's rule (to 80% of their luminance at bedtime, never under 7 : 1 and 4.5 : 1 on the night's surfaces); on the night slab, clay's inks, deepened by clay's rule only as far as its floors on clay's surfaces take. That the floors then hold on the slab itself is not assumed: the slab is a little lighter or darker than the surfaces each rule was solved against, so the tests measure ink, quiet ink, the orange as a fill and its letter on the slab at full, evening and bedtime (the table). The tightest is the day slab's orange fill at bedtime, 4.03 against a floor of 3, and its letter, 4.54 against 4.5.

**Decided in the build** (each worth the owner's eye):

- **Not every surface in the table has a chosen row.** Keep's action menu and the ⌘K card are fired by the keys they show, and nothing in them is chosen; the table's row stands for Keep's source list, which is. They stay as they are, and nothing lights in them.
- **A Keep card with a menu open stays the slab.** The card the actions act on is the chosen card, so it is the slab, but its paste key rests: with a menu open the keys answer the menu. With the list of sources open, the choice is in the list and no card is the slab.
- **A Settings search result shows ⏎,** lit, at its end: the key that lands there, as the bars show ⏎ on their chosen row. Its address letters rest. A Settings row a search landed on, or the keys are on, shows no key lit: nothing on it acts.
- **The microphone in use is a dot in the ink,** not the accent, in the input menu and in Settings' popups, as Settings' own dots are: nothing on a slab but the acting key is orange, and the colour contract keeps the orange for the key, the switch and the cursor.
- **The naming card for a Keep is the slab,** being the thing the keys are on.

## Main lessons

- **Resolve in the slab's look, not at the call.** `BarTheme.accent` was fixed to the Mac's look when asked for, so a lit key inside a day slab would have been clay's orange on a dark face. The orange and the letter on it are now dynamic colours like the ink.
- **A look changes the width of words.** The night sets text a step heavier than the day, so a day slab's night text is wider than the card was laid out for ("Ghostty" became "Ghos…"). A chosen card measures its single-line words again after it takes the other look.
- **A slab built by someone else's rows.** Settings' rows are plain views with the step laid behind them, so the step takes the row into the other look and gives it back when it goes, and follows the window if the Mac turns while it stands.
- **Pictures stay as they are,** and a picture that chooses a twin by the look it is drawn in (the walk's) is held in the look around the slab.
- **The harness hid a broken sheet.** The gallery's open choice menu rendered empty on main: menu item views have a frame and no constraints, and a stack gave them no size. It now gives them one.
- **The keys sheet lit every key on a chosen row,** which is the thing the slab forbids; it lights the one.

## Prototype lessons

- **Reserve what you draw.** The prototype's slab stood on a side that hung below its row, where the next row drew over it; the side belongs inside the frame.
- **Resolve in the slab's look.** Dots and chips baked as CGColor kept the surrounding look when their row flipped; everything in the slab resolves under the slab's appearance in the draw pass.
- **One lit key.** Lighting the address with ⏎ made three orange keys on one row.

## Decided in review

- **Keep's chosen card is the slab, whole** (23 October 2026): one rule everywhere, and the only mark that finds the chosen card among nine at a glance. A card whose top band alone was the slab read as a label rather than a choice.
- The design, the one lit acting key, and the surfaces are approved as drafted.
