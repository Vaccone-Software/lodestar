# Lodestar: Design Specification

> A keyboard driven macOS window navigation and layout system: one instrument replacing a window manager and a launcher.
> Named **Lodestar**: the fixed star you steer by. Every window you care about becomes one.

## Core philosophy

Destination over process. Every action names where you want to be and takes you there in one stateless gesture. No sequential traversal, no cycling, no ambient modes you can be stranded in. The goal is not "fast navigation," it is navigation that compiles into motor memory and stops being navigation. Every act is a stable address you summon.

Test for any feature: does it become a fixed gesture the hand owns, or does it force a fresh decision every time? If the latter, it does not belong.

## The addressing axis (the spine)

Every primitive addresses one of two things, and this distinction is forced by the nature of each:

- **Apps** are stable, launchable, singular. A key can always resolve to an app, and can always relaunch it. Addressed by: **searcher** and **graph**.
- **Specific windows** are instance-bound. The whole point is to pin _this_ Ghostty window out of ten. A window is not durable, cannot be freely recreated, and its identity can churn across close/reopen. Addressed by: **breaths**.

Consequence: app-scoped primitives (searcher, graph) are the safe bedrock. Window-scoped primitives (breaths) carry the real technical risk and depend on window-identity stability. Build the bedrock first.

## The four primitives

### 1. Searcher (the entry point)

A simple fuzzy-match app searcher. This is how an unaddressed app first enters the system; the other primitives are what you graduate things into from here. It also subsumes any "menu of all apps," so no such menu is needed.

- Plain `enter`: focus-or-launch the app, full-screen.
- `shift + enter`: open the app beside the current layout.

(v2 refinement, deferred: searcher may surface individual windows, not just apps: show the app when there is one instance, show windows when there are several. Decide this by using it, not by reasoning now.)

### 2. Graph (permanent apps)

`lode` + a chain of letters resolves deterministically to an app or a sub-target of an app.

- Single app: `lode S` -> Slack.
- Subdivided app: `lode B P` / `lode B G` / `lode B X` -> Brave profiles (personal / Google / work).

Focus-or-launch: if it exists, focus it; if not, create it. Always full-screen. The extra letters compile into muscle memory and stay deterministic. Cycle detection on the graph. App-scoped.

### 3. Marks (retired in 0.9.14)

Marks were letter addresses for **specific windows** — the temporary tail of
things not worth promoting to the graph. Shipped on `` ` ``, removed once the
design that followed had absorbed the need: the graph addresses apps (including
browser profiles) and nests arbitrarily deep, so rare destinations live one
letter further in rather than in a second namespace; `lode ⇥` reaches the other
windows of an app; and breaths address saved arrangements. What marks alone
could do — pin one live window out of ten — never justified a second register
to remember or the premium key it held.

The lesson kept: a mark bound a **live window ID**, so it died whenever its
window closed. Any future address for "this specific thing" must survive the
thing being gone, the way a breath relaunches what it needs.

### 4. Breaths (saved layouts)

A breath is a **snapshot** of a specific-window layout. It is not a mode. You compose a layout live (with shift, below), then save it, and can return to it later.

- `lode B` + a letter chain: save / return to a breath (addressed like the graph, e.g. `lode B G B`).
- `lode B B`: update the latest breath to the current layout. (Reserves the `B B` path from being an address.)
- A snapshot does not auto-update. To edit: add a window with shift, or remove one by closing it, then `lode B B` to commit. To revert, re-summon the breath.
- Persistence: session-first is guaranteed; cross-restart is best-effort (relaunch the parent apps, reposition as well as macOS allows). Breaths pin specific windows, so restore is inherently best-effort.

Breaths pin specific windows, so they carry the window-identity risk in full.

## Shift: the universal "beside me" modifier

One rule, applied everywhere. Plain invocation of any app-opener (searcher, graph) means "take me there, full-screen." The same invocation with `shift` means "bring it beside my current window." The new window opens to the right or below the active one depending on orientation.

This is the only mechanism that composes multiplicity, and it does so in the moment, with the intent declared in the gesture and gone immediately after. There is no compose mode to forget you are in. Shift-open repeatedly to build three or more windows.

## Layout and index navigation

- **Resting posture**: one app, full-screen. Multiplicity is always something you explicitly invoked (shift, or returning to a breath). You can never be confused about what you are looking at.
- **Equal sizing**: windows in a multi-window layout are equal-sized.
- **Index navigation**: `lode` + a number jumps to a window by index, left-to-right then top-to-bottom.
  - `lode 1` = leftmost / topmost. `lode 9` = rightmost / bottommost (Chrome-style: always the last, even if fewer than nine).
  - Cap at ten windows. Beyond that is not usefully navigable; prevent the instance rather than support it.
  - `0` is likely redundant (1 already covers first). Leave unassigned for now.
- **Close behavior**: closing a window in a multi-window layout retiles the survivors to equal-sized. This preserves index order, which protects the muscle memory built on it.
- **Orientation**: commands to flip a layout between all-horizontal and all-vertical.

## Technical approach

- **Language**: Swift. Binding directly against the C Accessibility APIs, no bridge tax.
- **Move / resize / focus**: public Accessibility API (`AXUIElement`).
- **Window identity**: one private, read-only call, `_AXUIElementGetWindow`, to bridge an AX element to a stable `CGWindowID`. This ID is the durable handle breaths pin to. Mature tools in this space rely on exactly this one private call and nothing else.
- **Hide**: park the window off-screen, beyond the union of all display bounds (must account for multi-monitor so parked windows do not peek onto a second display). A parked window stays live and its `CGWindowID` is unchanged; toggling back is one position change (milliseconds).
  - `cmd H` app-hide is a clean nice-to-have for the app-scoped case (removes an app's windows entirely), but it is per-application, so useless for hiding one window among several.
  - Minimize-to-Dock is a rare fallback only: it animates, is slower, and restores less reliably.
- **SIP stays ON.** The single private call does not require disabling it. Native Spaces manipulation does, so do not touch Spaces at all.

## Dependencies

Do not depend on existing window management libraries; this project _is_ that layer, and carrying foreign abstractions would fight the design. Instead:

- Learn the hard-won lesson of prior resolvers up front: raw AX calls are synchronous and block on the target app's event loop, so one hung app can freeze the whole switcher for seconds. A cached model is the answer. Learn this trap early rather than rediscovering it painfully.
- One cross display truth: to move a window across displays, set size, then position, then size again, because macOS clamps sizes to the current display.

Own everything else.

## Build order

**Slice 0, the probe (throwaway):** Before any UX, validate window-identity viability. Enumerate windows, get their `CGWindowID`s via the private call, park one off-screen and pull it back, and confirm the ID survives a close-and-reopen for the actual target apps (Brave, Ghostty, ProtonMail). Green light = IDs stable and reposition works, so window-scoped addressing is viable. Red = it demotes to session-only. This one result could reshape everything above it, so it is the first code written.

**Slice 1:** Searcher + focus-or-launch, full-screen. This alone is a usable app switcher, and it is the resolver every other primitive sits on.

**Slice 2:** Graph, on the same resolver.

**Slice 3:** Marks (since retired — see above). First real window-identity risk, isolated on top of a foundation already trusted.

**Slice 4:** Breaths. Specific windows plus layout.

**Later:** Layout undo/redo (a nicety with no downside). Counts and dot-repeat on close/resize verbs.

## Open questions (resolve by prototype, not reasoning)

- **Window-identity stability** across close/reopen for the specific apps in use. The probe answers this.
- **Namespace reservation**: `M`, `B`, and the digits are reserved as first characters (marks, breaths, index — marks and breaths since moved off letters entirely). Apps whose natural first letter is one of these need another path in the graph. Note in particular that Brave (`lode B ...`) currently collides with the breath prefix; one of them moves.
- **Searcher windows vs apps**: whether the searcher surfaces individual windows (v2).
- **Index `0`**: what, if anything, it does.
