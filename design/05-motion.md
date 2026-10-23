# 05 · Motion

Lodestar answers at once. Nothing it does a hundred times a day moves; motion is kept for the few things that report a signal, and nothing ever fades in to soften its own arrival.

## What it is for

Motion has a cost: every animation is time the hand waits for the eye. In a keyboard tool the hand is usually ahead of the eye already, so the honest default is no motion. Motion earns its place only when it carries something the end state cannot: a level that is changing right now.

## Origin

- **Frequent things do not animate** (decided with Ceramic, 20 October 2026). A response under about 100 milliseconds reads as instant (Nielsen); a surface opened four hundred times a day that eases in for 250 milliseconds costs a minute and a half of waiting a day, and reads as a delay in costume. Lodestar's panels already appear at once.
- **No flashes, by brightness, not by fade.** A fade is the usual cure for a bright panel opening in a dark room. Lodestar's cure is the palette: a surface is never brighter than the moment allows (Eye comfort), so it can appear at once without a flash.
- **What is left.** Main still moves five things: the switch's knob (a 0.18-second slide and a colour cross-fade), the draft's voice meter (a 0.35-second fall), the draft folding open or shut (0.1 seconds), the keys sheet a bar, the draft or the pill grows to show (0.3 seconds out, 0.22 back, with the keys fading in), and one shared curve for all of them.

## Values

### Instant

Everything a hand does often, and everything that appears:

- opening and closing any surface (a bar, the draft, Keep, the pill, a chip, Settings, a sheet)
- typing, a selection moving, a key lighting, a row becoming chosen, a press collapsing a side
- a list growing or shrinking as results change, a panel resizing to fit them
- the draft folding open or shut
- the keys sheet growing out of a bar, the draft or the pill, and its keys appearing
- a page changing in Settings or the walk
- Eye comfort's level changing (a step too small to see), receding and returning

### Allowed to move

| What                    | Why it moves                                      | How                                                     |
| ----------------------- | ------------------------------------------------- | ------------------------------------------------------- |
| the draft's voice meter | it is a level that is changing now                | follows the voice; falls over 150 ms when it drops to a lower level, and goes out at once |
| the switch's knob       | a rare change of state; the travel says which way | slides over 120 ms; the track's colour changes at once  |

### The curve

One curve for the two things that move: decelerating, `(0.25, 0.1, 0.25, 1)`, the curve main already uses. Nothing springs, bounces or overshoots.

### Reduce Motion

Nothing moves. The meter holds still at its full length while it is listening, so it still says listening; the knob jumps.

## Rules

1. **Instant by default.** A change appears in its end state on the next frame. Anything not in the table above does not animate.
2. **No fades.** Nothing fades in or out: not a surface, not its keys, not a colour. A colour changes at once.
3. **Motion carries a signal or nothing.** Only a live level and a rare change of state may move, and never for longer than 150 milliseconds.
4. **Correctness never waits on motion.** Where something does move, its end state is set first and the motion is a picture of getting there; if the motion is dropped, nothing is wrong.
5. **Reduce Motion stops everything,** including the two that are allowed.

## Enforcement

- A drift test fails on `NSAnimationContext` groups with a non-zero duration, `animator()`, Core Animation animations, `CATransition` and alpha fades in the app's sources, outside the meter and the knob.
- A test holds the two allowed motions to their durations and the curve, and to none under Reduce Motion.
- A test opens and closes every surface and holds each to its end state with no animation attached.

## Renders

Motion does not render in a still; the gallery shows end states, which is the point. The motion sheet, `foundation-motion`, lists every animation the app can run, read from the code.

## Status

Built 22 October 2026. Before it, main slid the switch's knob over 0.18 seconds with a colour cross-fade, let the voice meter fall over 0.35 seconds, folded the draft over 0.1 seconds, and grew the keys sheet over 0.3 seconds and shrank it over 0.22, fading its keys in after 0.08. The constants live in `Motion.swift`. A disabled row's 0.45 dim is a state, not a fade, and stays until the primitives decide how a disabled thing looks.

## Lessons from main

- **A window animation can fail under load.** The draft's fold already guards for it: when its time is up, the panel is put exactly where the layout said, whether or not the motion ran (rule 4). Making the fold instant removes the guard's reason to exist.

## Decided in review

- The switch's knob keeps a 120 ms slide: it is rare, and the travel says which way it went (22 October 2026).
