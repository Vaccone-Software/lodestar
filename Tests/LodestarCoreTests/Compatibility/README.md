# Released formats

What each release wrote, kept as the bytes it wrote, so that today's build
proves it still reads them (`CompatibilityTests.swift`, Stoic design/32).
One folder per format, one per release; `_schema.json` is that release's
reader as JSON Schema. Record a release with
`scripts/record-compat-fixtures.sh <release>` from its own commit.

A release name here is the release a shape was first written by, and it
stands for every later release until the next folder: a shape that did not
change has no folder of its own.

## feedback-entry (the outbox's note, `FeedbackEntry.codec`)

- `0.50.0`: the first release with the outbox, and so the first to write an
  entry. `FeedbackEntry.swift` (blob 5151eb68) and `Feedback.swift` (blob
  e642a2dd) are byte-identical at every tag from v0.50.0 to v0.54.22, so
  these bytes stand for 0.50.0 through 0.54.22. They are the codec's own
  output (sorted keys, compact), and the `_schema.json` is that decoder
  written out by hand: `schema` an integer of 1 or more, the note's four
  strings, the report optional, other keys left alone.
- Before 0.50.0 there was no queue: a note that did not send was copied to the
  clipboard.

## config (`lodestar.json`, `ConfigFile.schema`, read as the store reads it)

Rebuilt from `git log -p` of the schema; each folder is a release whose
schema differs from the one before it.

- `0.50.0`: the hand-edited store lands over an untyped tree
  (`ConfigDefaults.tree`: `appearance.accent`, `health.keyboards`, no
  `health.born`).
- `0.51.0`: `ConfigFile`, the typed schema; `health.born`, `health.hand` and
  `health.exact-keyboards`.
- `0.53.0`: `appearance.accent` retired, `appearance.eye-comfort` added.
- `0.54.0`: `health.born` and `health.hand` leave the file (they move to the
  health record).
- `0.54.1`: `health.exact-keyboards` leaves.
- `0.54.2`: `app.mouse-scrolling` added. `0.54.6` retires it.
- `0.54.5`: `draft.editing-style` added.
- `0.54.8`: `mice.reversed-wheels` added. The schema has not changed since.
- `0.54.22`: the last release before this one. Its samples are the shape
  0.54.8 settled; its `_schema.json` was exported by the 0.54.23 tree, whose
  `ConfigFile.swift` is byte-identical to v0.54.22's (blob 9013a466), because
  that release ran Stoic 0.4.2 and its own exporter is not rebuilt here.
- `0.9.10`, `0.21.0`, `0.40.0`, `0.43.0`: the old spellings a file may still
  carry (`hyper`; the profile registry, `gestures.searcher`,
  `gestures.back-forward`; `observations.enabled`, `gestures.menu-search`,
  `gestures.cheat-sheet`; `appearance.background`, `gestures.tabs`), under
  the last release that wrote each, as `ConfigFile.schema` reads them
  (`.normalizing`, `retired:`).

The `defaults` files are the header alone: what a first launch writes and a
sparse file with nothing changed looks like. Values are made up; no person's
file is kept here.

## state (`state.json`, sealed at rest as `state.sealed`; `PersistedState`)

One folder per change of `PersistedState`'s shape, found with `git log` over
`Stores.swift` (the writer's own sorted-key compact JSON, dates as seconds
since 2001):

- `0.9.0` has `marks`; `0.9.14` drops it; `0.11.0` adds `onboardedVersion`;
  `0.18.0` adds `parkedSession`; `0.20.0` swaps `onboardedVersion` for
  `walkStep` and `walkCompletedVersion`; `0.21.0` adds `meetingSpent`;
  `0.24.5` adds `coachStandingSince`; `0.30.15` adds `curriculum`; `0.37.0`
  adds `editorConsentAt`; `0.39.0` adds `walkDoor`; `0.54.5` adds
  `editingStyleSettled`; `0.54.11` adds a breath member's `display` and a
  breath's `orientations`.
- `0.54.22`: the last release before this one, the shape 0.54.11 settled.
  Its `_schema.json` is `PersistedState`'s decoder written out by hand (a
  non-optional Codable property is required when its key is absent: `breaths`
  and `parked`).

The sample files are written to match each release's struct (`git show
<tag>:Sources/LodestarCore/Stores.swift`) and are read, as the app reads them,
through `StateMigrations.lift` and `JSONDecoder`.
