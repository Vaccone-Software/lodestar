# 04 · Material

Matte ceramic, opaque, lit from above. Every surface is one solid colour with a polished rim along its top edge and a hairline around it; depth is a visible side, and it follows role.

## What it is for

Material is what a surface is made of, and so how it shows what it is: a pane you read from, a key you press, a well you put something in. One material, honestly drawn, means the same thing reads the same way on every surface, by day and by night, over any desktop.

## Origin

- **Glass retires** (decided 20 October 2026). Lodestar's panels were glass: macOS's material, tinted, with a veil in the ground's colour inside it at 0.9 to take the desktop's vote. The readability section spent a page measuring how the tone still drifted with whatever lay behind a panel. Glass also contradicted the rest: honest matter, keys that are keys. Matte ceramic was chosen over machined metal, paper and lacquer on the canvas "Lodestar Design Languages" because it is calm, warm, and has an edge the light can catch.
- **Depth by role.** The search refused two directions of elevation as a rule ("things rise, nothing sinks") and then found it too strict: a field and an empty keepsake are places you put something, and they read best sunk. So depth follows role: what you press stands up, a place you put something sinks, the rest is flat.
- **Thickness, not shadow.** A key's side survives the night, where a shadow does not, so depth reads the same in both looks without a second recipe.

## Values

### The pane

| Part   | Day                                          | Night                            |
| ------ | -------------------------------------------- | -------------------------------- |
| fill   | clay pane `#F6EFE8`, opaque                  | espresso pane `#1D1916`, opaque  |
| rim    | 1.5 pt along the top, clay key step          | 1.5 pt along the top, ink at 10% |
| edge   | 0.5 pt all round, ink at 10%                 | 0.5 pt all round, ink at 8%      |
| shadow | one, soft: quiet ink at 14%, 24 blur, 8 down | none                             |

The rim is clipped to the pane's corners, so it thins into the curve where the surface turns away from the light. The edge is drawn above the pane's content, so a picture that fills the pane does not cover it. The shadow follows the pane's outline.

### Depth by role

| Role      | What                                                                                                   | How it is drawn                                                                     |
| --------- | ------------------------------------------------------------------------------------------------------ | ----------------------------------------------------------------------------------- |
| stands up | anything you press: a key, a button, a popup, a switch's knob, the chosen thing                        | a face on a visible side, the look's side colour beneath it                         |
| sinks     | a place you put something: a field, an empty keepsake, a drop target                                   | a well: one step below the pane it sits in, a 0.5 pt edge, no side, no inner shadow |
| flat      | everything else: panes, cards that are not pressed, groups, chips that only say something, a quiet key | the surface's own fill, at most a hairline                                          |

**The side.** A band of the side colour beneath the face, as tall as its size calls for: 3 points at a control's size, 4 at a row's, 5 at a large key's. Pressing collapses it to 1 point at once, the face moving down by what the side gave up. The side sits inside the thing's frame (geometry, rule 6).

**The well** by day is the pane darkened by 0.025 in lightness (about `#ECE4DC` in a clay pane); by night it is the pane darkened by 0.02, never below the ground.

### Weights retire

Glass had three weights (normal, raised, faint), each a different opacity. An opaque material has none: a surface is a pane, a key step, or the ground, by its role.

## Rules

1. **Opaque.** Nothing Lodestar draws lets the desktop through. No glass, no blur, no vibrancy, no transparency setting to honour, because there is nothing to make opaque.
2. **One light, from above.** Every rim is on a top edge, every side beneath a face, every shadow falls down. Nothing is lit from the side or below.
3. **Depth follows role.** Stands up, sinks, or flat, by what the thing does. Nothing sinks only to make its neighbour look raised, and nothing stands up that cannot be pressed.
4. **Thickness over shadow.** Pressability is a side, never a shadow. A shadow only separates a floating pane from the desktop, and only by day.
5. **No gradients, no inner shadows, no glows.** A face is one colour; a well is one colour and an edge.
6. **The edge is on top.** A pane's hairline and rim are drawn above its content.
7. **Content is not material.** Pictures, app icons and previews are drawn as they are, with no rim, edge or side of their own unless they are a key.

## Enforcement

- A drift test fails on any glass, visual-effect or vibrancy type, or a window that is not opaque, outside debug previews.
- A test holds the pane's fill, rim, edge and shadow per look, and the well's step.
- A gallery test checks every pressable thing has a side, every well has none, and every flat thing has neither; and that pressing collapses a side to 1 point.

## Renders

`foundation-material-{day,night}`: a pane with its rim, edge and shadow over a light and a dark desktop; the three roles side by side; a key resting and pressed. Then every surface: with glass gone, the gallery shows exactly what is on screen.

## Status

Not yet built. Main's panels are glass (`TonedGlass`, an `NSGlassEffectView`, with a visual-effect fallback) with a veil at 0.9, 0.94 or 0.8 by weight; keys stand on a hard 1.5-point shadow as their side, with a lit top edge; a quiet key sits in a shallow well; a lifted card casts a small shadow by day.

## Prototype lessons

- **Draw the edge last.** Content that filled a pane (a picture, the walk's tiles) covered the pane's hairline until the edge moved above it.
- **One edge per object.** A pane hosted inside a card that draws its own edge drew two; the inner one must stand down.
- **Repaint in the view's own look.** A layer colour set once keeps the look it was set in; the pane paints in its draw pass under its own appearance.

## Open

- Whether night panes want a faint shadow (espresso ground at 40%) over a dark desktop, or the hairline alone is enough.
