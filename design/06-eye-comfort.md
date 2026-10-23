# 06 · Eye comfort

The one appearance setting. Through the evening Lodestar makes its own surfaces dimmer and calmer, at bedtime it takes the night look, and a surface you leave alone grows quieter. On by default, one switch, and it never touches what you copy or view.

## What it is for

A screen is brightest when the room is darkest. Lodestar cannot dim the Mac, but it can stop its own panels from being the brightest thing in a dark room, and it can do so without being asked, the way a good lamp does. The claim is comfort, not sleep.

## Origin

- **Decided with Ceramic** (20 October 2026): one setting, named for its purpose, "Eye comfort", on by default with one off switch. The schedule follows the sun, because a fixed schedule is wrong half the year; bedtime brings the night look; receding is housed here because it is the same idea in space rather than time.
- **Brightness, not hue.** The Lighting Research Center's study of Night Shift found that brightness, not colour temperature, decides what evening light does. So Lodestar dims and never tints; colour temperature stays with Night Shift.
- **Dimming is luminance.** The prototype dimmed by 12% of perceptual lightness, which is about a 35% cut in luminance: clay turned grey, quiet ink fell under its floor, and the orange went brown to stay readable. The research's figures are luminance. Dimmed as luminance, clay stays clay.
- **Sleep Focus cannot be read.** macOS tells an authorised app only that a Focus is on, not its schedule, so bedtime is estimated from sunset.

## Values

### The schedule

| When                       | What Lodestar's own colours do                      |
| -------------------------- | --------------------------------------------------- |
| day                        | full                                                |
| sunset to one hour after   | ease to 96% of their luminance                      |
| one to three hours after   | ease to 88% of their luminance; the orange calms    |
| bedtime until sunrise      | the night look, even while the Mac is light, at 88% |
| sunrise to two hours after | ease back to full                                   |

**Which colours dim:** the bright ones. In the light look, the surfaces (ground, pane, key, side); in the dark look, the ink, quiet ink and the clay slab. Every channel is scaled together in linear light, so hue and saturation are exactly unchanged.

**At the deepest level, by day:** pane `#E9E2DB`, key `#EEEAE7`, ground `#E0D7CE`; ink 13.7 : 1 and quiet ink 5.3 : 1 on the pane.

**The orange calms:** its chroma falls by up to 10% at the same hue, and its lightness falls just enough to keep 4.5 : 1 as text on the dimmed pane: `#B6360C` by day at the deepest level.

**The sun** is computed from the Mac's time zone: the zone's own coordinates from the system's zone table, then the standard solar formulas. No location is asked for. Where the sun does not set or rise, sunrise is 07:00 and sunset 21:00.

**Bedtime** is four hours after sunset, held between 21:30 and 00:30, and lasts until sunrise.

**Steps.** The level is worked out every five minutes and on waking, a clock change or a time-zone change. Each step is under 1% of luminance, so none is seen; the switch to the night look at bedtime happens at once, because it only gets darker. At sunrise the day look returns at 88% and eases up from there: the one step that brightens, at the hour the room is brightening too.

### Receding

The pill and the meeting's chip stay on screen while the work is elsewhere. After 20 seconds without attention their ink moves toward their pane, to 5.5 : 1, and their quiet ink to 4.5 : 1, so the two keep their order. They come back at once on hover, a key, a change of state, or when the meeting is due. A lit key never recedes.

### The setting

In Settings, General, under "Sound and display": a switch titled **Eye comfort**, described as "Lodestar adjusts its own surfaces through the day to be easier on your eyes: dimmer and softer after sunset, dark at bedtime, and quieter when you're not using them. What you copy and view is never changed". The config key is `appearance.eye-comfort`, true by default.

## Rules

1. **Never tints.** Lightness moves; hue and saturation do not.
2. **Never touches content.** Images, swatches, previews and app icons are drawn as they are at every hour.
3. **The floors hold at every hour.** Ink 7 : 1, quiet ink and the orange as text 4.5 : 1, a lit fill 3 : 1, at every point of the schedule and while receded.
4. **No visible step.** Changes are too small to see, except bedtime, which only darkens, and sunrise, which returns the day look at its dimmest.
5. **Off is exactly off.** With the switch off, Lodestar follows the Mac's look at full level and nothing recedes.
6. **Type follows the look.** At bedtime the night look's heavier weights come with it (type contract).

## Enforcement

- Pure tests in Core: sun times against almanac values for several cities and the polar fallback; bedtime's clamp; the level at every minute of a day; hue and saturation unchanged; every floor at every level, by day and by night.
- App tests: the theme reads the level from one place; bedtime takes the app to the night look and back; receding moves the pill's and the chip's ink to their floors and back at once; off leaves everything at full.
- The colour sheet renders at the deepest level and at bedtime as well as at full.

## Renders

`foundation-colour` at full, deepest and bedtime; the launcher, Settings, Keep and the pill at the deepest level and at bedtime; the pill and the chip receded.

## Status

Not yet built. Main has no Eye comfort: it follows the Mac's look at full level, and nothing recedes.

## Prototype lessons

- **Dim luminance, not lightness.** The prototype's grey clay and brown orange came from dimming perceptual lightness by 12%.
- **Receded inks converged.** Moving both inks toward the pane made ink and quiet ink nearly the same grey; they now recede to different floors.
- **Repaint from one place.** The prototype called every view's appearance callback on each level change; the level should live where the palette is resolved, so a surface repaints the way it does for a look change.

## Open

- Whether the night look should dim at all when the Mac is already dark in the evening (it does here, to 88% of the ink's luminance, 13.1 : 1).
