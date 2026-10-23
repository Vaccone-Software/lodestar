# 06 · Eye comfort

The one appearance setting. Through the evening Lodestar makes its own surfaces dimmer and calmer, dimmer still late at night, and a surface you leave alone grows quieter. It always follows the Mac's own look. On by default, one switch, and it never touches what you copy or view.

## What it is for

A screen is brightest when the room is darkest. Lodestar cannot dim the Mac, but it can stop its own panels from being the brightest thing in a dark room, and it can do so without being asked, the way a good lamp does. The claim is comfort, not sleep.

## Origin

- **Decided with Ceramic** (20 October 2026): one setting, named for its purpose, "Eye comfort", on by default with one off switch. The schedule follows the sun, because a fixed schedule is wrong half the year; receding is housed here because it is the same idea in space rather than time.
- **No night look at bedtime** (22 October 2026). The first draft took Lodestar's surfaces dark at bedtime even while the Mac was light. A dark room is the case for dark, and people work in dark rooms long before bedtime and sometimes never; Lodestar cannot see the room, and the Mac's appearance is the person's own answer (Auto takes every app dark together at sunset). A panel that turned dark on its own would be the odd one on a light screen and would break the rule that a surface follows the look the person chose. What the evidence supports is less light, so bedtime brings a deeper dim instead.
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
| bedtime until sunrise        | ease to 80% of their luminance                                   |
| sunrise to two hours after | ease back to full                                   |

**Which colours dim:** the bright ones. In the light look, the surfaces (ground, pane, key, side); in the dark look, the ink, quiet ink and the clay slab. Every channel is scaled together in linear light, so hue and saturation are exactly unchanged.

**In the evening, by day's look:** pane `#E9E2DB` at 88%, ink 13.7 : 1 and quiet ink 5.3 : 1. **At bedtime:** pane `#DFD9D2` at 80%, ink 12.5 : 1 and quiet ink 4.9 : 1. Clay cannot go much deeper: quiet ink reaches its floor near 72%.

**The orange calms:** its chroma falls by up to 10% at the same hue, and its lightness falls just enough to keep 4.5 : 1 as text on the dimmed pane. In the dark look it dims with the ink, but never below 4.5 : 1 as text.

**The sun** is computed from the Mac's time zone: the zone's own coordinates from the system's zone table, then the standard solar formulas. No location is asked for. Where the sun does not set or rise, sunrise is 07:00 and sunset 21:00.

**Bedtime** is four hours after sunset, held between 21:30 and 00:30, and lasts until sunrise.

**Steps.** The level is worked out every five minutes and on waking, a clock change or a time-zone change. Each step is under 1% of luminance, so none is seen, bedtime's deeper dim included.

### Receding

The pill and the meeting's chip stay on screen while the work is elsewhere. After 20 seconds without attention their ink moves toward their pane, to 5.5 : 1, and their quiet ink to 4.5 : 1, so the two keep their order. They come back at once on hover, a key, a change of state, or when the meeting is due. A lit key never recedes.

### The setting

In Settings, General, under "Sound and display": a switch titled **Eye comfort**, described as "Lodestar adjusts its own surfaces through the day to be easier on your eyes: dimmer and softer after sunset, dimmer still late at night, and quieter when you're not using them. What you copy and view is never changed". The config key is `appearance.eye-comfort`, true by default.

## Rules

1. **Never tints.** Lightness moves; hue and saturation do not.
2. **Never touches content.** Images, swatches, previews and app icons are drawn as they are at every hour.
3. **The floors hold at every hour.** Ink 7 : 1, quiet ink and the orange as text 4.5 : 1, a lit fill 3 : 1, at every point of the schedule and while receded.
4. **No visible step.** Every change is too small to see.
5. **The Mac chooses the look.** Lodestar never changes between light and dark on its own; Eye comfort only dims within the look the Mac is in.
6. **Off is exactly off.** With the switch off, Lodestar is at full level and nothing recedes.

## Enforcement

- Pure tests in Core: sun times against almanac values for several cities and the polar fallback; bedtime's clamp; the level at every minute of a day; hue and saturation unchanged; every floor at every level, by day and by night.
- App tests: the theme reads the level from one place; Lodestar never leaves the Mac's look; receding moves the pill's and the chip's ink to their floors and back at once; off leaves everything at full.
- The colour sheet renders at evening and bedtime as well as at full.

## Renders

`foundation-colour` at full, evening and bedtime, in both looks; the launcher, Settings, Keep and the pill at evening and bedtime; the pill and the chip receded.

## Status

Not yet built. Main has no Eye comfort: it follows the Mac's look at full level, and nothing recedes.

## Prototype lessons

- **Dim luminance, not lightness.** The prototype's grey clay and brown orange came from dimming perceptual lightness by 12%.
- **Receded inks converged.** Moving both inks toward the pane made ink and quiet ink nearly the same grey; they now recede to different floors.
- **Repaint from one place.** The prototype called every view's appearance callback on each level change; the level should live where the palette is resolved, so a surface repaints the way it does for a look change.

## Decided in review

- No night look at bedtime; a deeper dim (80%) instead, and the Mac's appearance always chooses light or dark (22 October 2026).
- In the dark look the ink dims too, to 80% of its luminance at bedtime (about 12 : 1, quiet ink 5.5 : 1). The orange dims with it only as far as 4.5 : 1 as text allows.

## Later

- **The room's own light.** The Mac's ambient light sensor would tell Lodestar how dark the room actually is, which the sun only estimates. macOS offers no public way to read it; worth exploring if that changes.
