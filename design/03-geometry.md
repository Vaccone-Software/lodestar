# 03 · Geometry

One curve, one grid, and the sizes everything is cut to. Radii come from the pill, spacing from a four-point grid, and a thing inside another follows its outline.

## What it is for

Geometry is what makes surfaces read as made by one hand: the same curve at the same scale, the same gaps between the same kinds of things, edges that line up. When each surface picks its own numbers, nothing is wrong on its own and everything is slightly off together.

## Origin

- **The ladder is kept and re-anchored.** Main already rounds on a ladder, each rung the one above over φ², anchored on the pill's height: a surface at 16.8, a control at 6.4, a mark at 2.5. Ceramic (20 October 2026) anchored it instead on the pill's own curve: the pill is 44 tall and fully round, so its ends have a radius of 22, and every surface now rounds like the pill's end. The ladder below it is unchanged in kind: 22, 8.4, 3.2.
- **Concentric nesting.** A row inside a pane rounds at the pane's radius today, so its corners sit closer to the pane's corners than its sides do to the pane's sides, and the two curves fight. A thing nested inside another rounds at the outer radius minus its inset, so the gap between them is even all the way round.
- **The grid is new.** Main's layout uses eighteen different gaps (2, 3, 4, 5, 6, 7, 8, 9, 10, 12, 14, 16, 18, 22, 26, 30, 32, 36), each chosen where it was needed. A four-point grid is the common answer and fits the type scale: 16 and 24 are on it, and 13 and 18 sit on its half-steps.
- **The prototype's layout bugs were all geometry:** a key column with a minimum width that stretched every key in it to 88 points, a footer cut off by a width computed as "the text's width minus 150", a key centred on a three-line row instead of on its title, and a selection's side hanging outside its row where the next row covered it.

## Values

### Radii

| Rung     | Radius         | What rounds here                             |
| -------- | -------------- | -------------------------------------------- |
| surface  | 22             | a panel, a card, the pill (whose ends it is) |
| control  | 8.4            | a key, a chip, a field, a popup, a button    |
| mark     | 3.2            | a highlight on text, a small badge           |
| hairline | half its width | a caret, a meter's bar                       |

Each rung is the one above over φ² (22 / 2.618 = 8.40; 8.40 / 2.618 = 3.21).

**Nested:** a thing inside another rounds at `max(rung, outer − inset)`. A row 12 points inside a pane rounds at 10; a field 12 points inside a pane rounds at 10; a key inside a row rounds at its own rung, 8.4, because the row's radius less the inset falls below it. A surface smaller than twice its radius is a stadium.

### Spacing

Every gap, inset and padding is a step of the grid:

| Step | Points | Typical use                                                 |
| ---- | ------ | ----------------------------------------------------------- |
| 1    | 2      | between a key and its side; a hairline's offset             |
| 2    | 4      | between keys in a sequence; a key's inner padding (half)    |
| 3    | 8      | inside a control; between an icon and its label             |
| 4    | 12     | a pane's inset to its rows and field; between a row's parts |
| 5    | 16     | between groups; a room's inset                              |
| 6    | 24     | between sections of a room                                  |
| 7    | 32     | a room's outer margin                                       |
| 8    | 48     | between a room's columns                                    |

Inside a control (a key's horizontal padding, a chip's) a half-step of 6 is allowed, because 4 crowds a letter and 8 makes a short key wide.

### Sizes

| Thing          | Size                    | Note                                               |
| -------------- | ----------------------- | -------------------------------------------------- |
| bar            | 640 wide                | the launcher, Ask, Commands: one instrument        |
| bar's field    | 60 tall                 | holds the 23-point field role                      |
| row            | 48 tall                 | one line of body with an icon                      |
| pill           | 44 tall                 | its ends define the surface radius                 |
| key            | 22 tall                 | the key contract sets its width and parts          |
| app icon in a row | 32               | its artwork carries its own margin                 |
| symbol in a row   | 16               | a symbol leading a row, at the body's size         |
| pointer target | at least 24 × 24        | anything clickable, though Lodestar is keyed first |
| measure        | 380 wide for a sentence | about 50 characters at the voice role              |

## Rules

1. **No literal geometry.** A radius, gap, inset or size in layout code names a token from this contract. A number written inline fails the build, except 0 and a hairline.
2. **Concentric.** Anything nested rounds at the outer radius minus its inset, never below its own rung.
3. **On the grid.** Every gap and inset is a step; the half-step 6 only inside a control.
4. **A column is as wide as what it holds.** A column of keys, labels or icons sizes to its widest item; no minimum width ever stretches its contents, and a column with nothing in it takes no space.
5. **Align on the first line.** In a row, the leading key, the icon, the title and the trailing control share the centre of the title's first line, however many lines of detail follow.
6. **Nothing hangs outside its frame.** A side, a shadow's offset, a badge: a view reserves the room for everything it draws, so no ancestor clips it and no sibling covers it.
7. **Widths come from content.** A container sized to text rounds its width up to a whole point, and text that can outgrow its track wraps or truncates by design, never because of a computed width.

## Enforcement

- A drift test reads the layout sources and fails on numeric radii, gaps, insets and sizes outside the tokens (0 and hairlines allowed).
- A test holds every rung to the ladder and the nesting rule on the panes, rows and fields that nest.
- Gallery-driven tests: in every surface, no view draws outside its own bounds; columns hug their widest item; a row's key, icon, title and control share the first line's centre within half a point.

## Renders

Every surface in the gallery. The geometry sheet, `foundation-geometry`, draws the ladder, the nesting rule on a pane and a row, and the grid's steps.

## Status

Not yet built. Main rounds surfaces at 16.8, controls at 6.4 and marks at 2.5; rows round at the pane's own 16.8 and do not nest; spacing uses eighteen values; the launcher's key column has a fixed width.

## Prototype lessons

- **A minimum width is a stretch waiting to happen.** The launcher's key column had a required minimum, and AppKit honoured it by stretching every key to it.
- **Computed widths truncate.** "The width less 150" cut a sentence in half when the sentence grew. Lay text out in its track and let it wrap.
- **Reserve what you draw.** The prototype's slab stood on a side that hung below its row, where the next row drew over it.

## Open

- Whether the bars stay 640 wide, now that every field is 23 points and a row's label is 16.
