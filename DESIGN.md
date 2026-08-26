# Lodestar: Design Specification

> A keyboard driven macOS window navigation and layout system: one instrument replacing a window manager and a launcher.
> Named **Lodestar**: the fixed star you steer by. Every window you care about becomes one.

## Core philosophy

Destination over process. Every action names where you want to be and takes you there in one stateless gesture. No sequential traversal, no cycling, no ambient modes you can be stranded in. The goal is not "fast navigation," it is navigation that compiles into motor memory and stops being navigation. Every act is a stable address you summon.

Test for any feature: does it become a fixed gesture the hand owns, or does it force a fresh decision every time? If the latter, it does not belong.

## The addressing axis (the spine)

Every primitive addresses one of two things, and this distinction is forced by the nature of each:

- **Apps** are stable, launchable, singular. A key can always resolve to an app, and can always relaunch it. Addressed by: **launcher** and **graph**.
- **Specific windows** are instance-bound. The whole point is to pin _this_ Ghostty window out of ten. A window is not durable, cannot be freely recreated, and its identity can churn across close/reopen. Addressed by: **breaths**.

Consequence: app-scoped primitives (launcher, graph) are the safe bedrock. Window-scoped primitives (breaths) carry the real technical risk and depend on window-identity stability. Build the bedrock first.

## The four primitives

### 1. Launcher (the entry point)

A simple fuzzy-match app launcher. This is how an unaddressed app first enters the system; the other primitives are what you graduate things into from here. It also subsumes any "menu of all apps," so no such menu is needed.

- Plain `enter`: focus-or-launch the app, maximized.
- `shift + enter`: open the app beside the current layout.

(v2 refinement, deferred: launcher may surface individual windows, not just apps: show the app when there is one instance, show windows when there are several. Decide this by using it, not by reasoning now.)

### 2. Graph (permanent apps)

`lode` + a chain of letters resolves deterministically to an app or a sub-target of an app.

- Single app: `lode S` -> Slack.
- Subdivided app: `lode B P` / `lode B G` / `lode B X` -> Brave profiles (personal / Google / work).

Focus-or-launch: if it exists, focus it; if not, create it. Always maximized. The extra letters compile into muscle memory and stay deterministic. Cycle detection on the graph. App-scoped.

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

## Ask (added after the four)

`lode ⏎` opens a second bar with its own grammar, on the axis the four primitives do not address: a destination **inside** an app. The four are about which window you are looking at; Ask is about which browser profile a URL lands in, which is the same question one level down.

It stays a separate bar rather than rows in the launcher, and that separation is the design. The launcher answers "which app," and mixing web destinations into it would put two kinds of answer in one list, forcing a read-and-reject on every query. Two bars, two grammars, no ambiguity — the cost is one more gesture to learn, paid once.

Three kinds of row, and the third is why it works: **links** (a name you typed for a site), **domains** (anything that looks like a destination), **searches** (everything else). Every row wears the profile it will open in. Profiles resolve by precedence — a link's pin, then a `web.routes` pattern, then `web.fallback`, then the browser you were in last — and every surface that shows a profile also shows _which_ of those decided it, because an inferred answer can change tomorrow and a chosen one cannot.

Routes are the piece that earns its keep quietly: a pattern matched against whatever you typed, host or query alike, so `x.com` always opening in Personal is one line of config rather than a habit.

They also reach **links clicked in other apps**, because that is the half of the problem that needs them: when you type into the bar you already had the chance to choose, and when you click a link you had none. Lodestar can stand as the http handler and apply the same table. That lives in the main binary rather than a helper app — a second download is a worse product when the rules are already configured here — and the design that makes it safe is inversion: **pass-through is the behavior, a matched rule is the exception**. The common path is the empty one, so a link cannot be lost by code that does nothing, and nothing changes for a user who never writes a rule.

Three constraints hold that path, each load-bearing. It touches config and LaunchServices only, never the window model, because a blocking AX call would let one wedged app delay somebody's link by seconds. It never places the window: a link someone sent you is not a request to rearrange your layout. And it never asks LaunchServices to open a URL without naming the target app, which is what stops the dispatch handing the link straight back to us forever.

Because the app updates itself daily, the update watchdog gained a functional gate: while Lodestar holds the browser role, a successor must prove its router answers, not merely that it booted. A window manager that cannot place a window is annoying and obvious; a build that cannot route a link fails silently, in other people's apps, on a machine where every link now depends on it.

Test it passes: the gesture is fixed (`lode ⏎`, type, `↵`), and the profile decision is removed from the moment of use rather than added to it.

**The diagnostics log carries none of it.** Not a URL, not a host, not a typed query — the log is paste-able (`lodestar diagnose` tails it), and a list of everywhere you went is not diagnostics. Where something opened is what a bug report needs. The observation layer is the one place a destination's _host_ is kept — local, bounded, and only because a host that always lands in the same profile is one route recommendation away from being config (see "What the app learns" below); the path and query stay nobody's. Config edits log the _name_ you chose, never the destination.

## The clipboard (added after the four)

`⇧⌘V` puts history on screen: recents along the bottom labelled by the home row, pins climbing the left edge numbered 1–3. Both meet at one corner, so the two things you are most likely to want — a pin, or what you just copied — are one hot region rather than two ends of a wide strip.

The strip is **never key**: it reads its keys from the event tap, so the window you were typing in keeps focus and its insertion point, and the paste is a plain `⌘V` into an app that never lost the cursor. History lives in `~/.local/share`, not `~/.config`, because the config is what people commit to a dotfiles repo and clipboard history is the last thing that belongs there. `clipboard.exclude` / `exclude-apps` are how something never gets recorded in the first place.

A clip is **whatever was copied**, not the first piece of it. The pasteboard carries items — three files selected in Finder are three of them — so a history that kept only the first would hand back a third of a copy while looking like it worked. And while the search band has the letters, `⌥` is what addresses a card: the chips stay on the cards and wear the modifier that makes them true, because a label you can see and cannot press is worse than no label.

_(This section describes what the code does; the framing is worth your eye.)_

## Select (added after the four)

`lode /` addresses the one thing on screen that never needed an assigned address: text is made of the characters the keyboard already produces, so its address is itself. Type a few characters of what you can see; matches highlight and wear capital chips; a capital anchors the start, a second search and capital anchor the end, and the span between them — in document order, whichever way it was placed, so no concept of direction exists — becomes the selection.

The split that makes it clockless: lowercase and symbols always extend the search, capitals always pick a chip. Labels are letters only, so `⇧4` is `$` and can never be a pick; matching is case-insensitive, so a real capital is never needed. This composes the two instruments the product already owns — incremental search and prefix-free hint chips — and inverts the arithmetic that kills pure hints on prose: a screenful of words outnumbers any label alphabet, but two typed characters collapse it to a handful.

The mode always ends the same way — **the span highlighted, the next verb the user's** — because a gesture that did different things on different text would put a read-the-situation step inside a fixed gesture, which is the one thing the design forbids. The first cut auto-copied read-only spans with a flash — one keystroke saved, at the price of the mode becoming the arbiter of intent; real use rejected it within a day.

That ending is reachable one pick early. The start anchor lands on the whole word rather than the characters that named it, so it is already a selection someone can see, and `⌘C` there takes it and ends the mode exactly as a finished span would: copied, still highlighted, the next verb yours. A second anchor is what a *span* needs, not what a *word* needs — and most of what a hand reaches for is one word. The mode still never decides that for anyone: the user asks with ⌘C, which is the auto-copy lesson kept rather than relearned.

**The sensor is the screen itself.** The first architecture harvested accessibility trees, and real use taught its lesson in one evening: trees build lazily, un-build after idle, answer geometry per app per element per mood, and draw element boundaries a span cannot cross. Pixels have none of those properties — the Vision framework reads a capture of the focused window and places any character range to the pixel, identically in a terminal, a browser, and a chat history. Consistency is the whole point of the mode, so pixels are primary; the Screen Recording permission is requested lazily on first use, and the accessibility harvest remains the permission-free fallback.

Accessibility's demotion is to the two jobs it is actually good at. **Grounding**: recognition of clean screen text fails only by single glyphs (`1`↔`l` — reproduced in our own tests), harmless in prose and catastrophic in an identifier, so a pixel-sensed copy is repaired against the accessibility-read truth when the two align. **Committing**: a sensed span that lives verbatim in the focused editable element becomes a true `AXSelectedTextRange` — the app's own highlight, every editor verb. Everything else ends as the held highlight, ⌘C serving the grounded text.

Fragmented text is stitched before matching (`SelectRuns`) — recognized lines merge exactly as accessibility leaves did: same line joins with the gap the layout drew, lines of one column join with newlines, and a span across fragments highlights as one honest rectangle per piece.

Stitching stays conservative on purpose, because an over-merged run promises spans across unrelated columns — which means most of a busy page arrives as runs one or two lines long (85 recognized lines became 58 runs on the first page measured, 44 of them a single line). So the span, not the run, is what had to cross: it takes the tail of the run it starts in, everything between in reading order, and the head of the run it ends in — what a drag down the page would have taken. Confining the far end to the anchor's own run was the alternative, and it put an invisible wall at the end of the line the eye happened to start on; the wall was the bug users hit, on GitHub, in a diff, in any chat log. Every piece is lit, and the copy is exactly the lit pieces joined by newlines — the highlight is the whole promise, so it may never be a summary of one. No app can be asked to select across its own element boundaries, so a span that crosses always ends as the held highlight, never a native one.

Test it passes: the gesture is fixed (`lode /`, type what you see, a capital — then `⌘C` for that word, or a second type-and-capital for the span), and the decision the mouse used to make with a drag is made by reading, which the eyes were already doing.

## Promotion: ⌘K on the thing in front of you

The bars share one editing gesture. `⌘K` acts on the selected row and offers only what that row can become: an app joins the graph, a domain becomes a named link or a route, a link can be routed or removed, a route can be removed from any row it sent somewhere. Every card shows what `↵` would commit before it commits it, and refuses with the reason rather than silently.

This is how things graduate. The launcher is where an unaddressed app first appears; Ask is where an unnamed destination first appears; `⌘K` is the one move that turns either into an address, and it writes straight into the config so the file and the UI are the same source of truth. Editing by hand and editing by card produce identical bytes.

The decisions live in `WebMenu` (LodestarCore), tested without an app; the panels only draw and translate keystrokes. Any future card belongs there too — a state machine wearing an AppKit coat is still a state machine.

## Shift: the universal "beside me" modifier

One rule, applied everywhere. Plain invocation of any app-opener (launcher, graph) means "take me there, maximized." The same invocation with `shift` means "bring it beside my current window." The new window opens to the right or below the active one depending on orientation.

This is the only mechanism that composes multiplicity, and it does so in the moment, with the intent declared in the gesture and gone immediately after. There is no compose mode to forget you are in. Shift-open repeatedly to build three or more windows.

## Layout and index navigation

- **Resting posture**: one app, maximized. Multiplicity is always something you explicitly invoked (shift, or returning to a breath). You can never be confused about what you are looking at.
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
- **Tone**: every surface follows the system appearance — one dark look, one light look, chosen by the user's own setting and never by the pixels behind a panel. Liquid Glass wants to adapt its tone per panel to the backdrop; that is how two panels a foot apart once resolved to opposite tones, and how text and ground once landed on the same color. We keep the frost and take away the material's vote: an equalizer scrim senses the material's choice and drags it to the system's tone (`Glass.swift`). A surface summoned for a second must cost zero reorientation, which means it must look the same every time — the gesture test, applied to the eye.

## Dependencies

Do not depend on existing window management libraries; this project _is_ that layer, and carrying foreign abstractions would fight the design. Instead:

- Learn the hard-won lesson of prior resolvers up front: raw AX calls are synchronous and block on the target app's event loop, so one hung app can freeze the whole switcher for seconds. A cached model is the answer. Learn this trap early rather than rediscovering it painfully.
- One cross display truth: to move a window across displays, set size, then position, then size again, because macOS clamps sizes to the current display.

Own everything else.

## Build order

**Slice 0, the probe (throwaway):** Before any UX, validate window-identity viability. Enumerate windows, get their `CGWindowID`s via the private call, park one off-screen and pull it back, and confirm the ID survives a close-and-reopen for the actual target apps (Brave, Ghostty, ProtonMail). Green light = IDs stable and reposition works, so window-scoped addressing is viable. Red = it demotes to session-only. This one result could reshape everything above it, so it is the first code written.

**Slice 1:** Launcher + focus-or-launch, maximized. This alone is a usable app switcher, and it is the resolver every other primitive sits on.

**Slice 2:** Graph, on the same resolver.

**Slice 3:** Marks (since retired — see above). First real window-identity risk, isolated on top of a foundation already trusted.

**Slice 4:** Breaths. Specific windows plus layout.

**Later:** Layout undo/redo (a nicety with no downside). Counts and dot-repeat on close/resize verbs.

## What the app learns (the observation layer)

Lodestar watches how you reach things — locally, deletably, off by one config line — so that one day it can coach: not dashboards, one earned sentence at a time. The architecture is decided by one lesson: **aggregate at read time, never at write time**. v1 stored a median per chain and the median turned out to confound chain length with fluency; the mistake was frozen into the data. So the source of truth is now an append-only event log (`events.jsonl`, ninety rolling days), and everything else — the summary file, every fitted model — is a view over it, rebuildable when the models improve. What is kept: pauses tagged by position and whether the map was up, abandons with their hover, the wrong key actually pressed, each road's measured price in seconds, app→app transitions, hosts and the profile they landed in. What is never kept: window titles, URL paths and queries, clipboards, launcher queries beyond two characters.

The analysis side holds itself to three disciplines. A pause is judged against what that chain's _shape_ costs this user's own hands (position and digraph regressed out), never against a constant. A recommendation must clear a decision-theoretic gate — probably worth more time than it costs, relearning priced from the user's own curves — and survive false-discovery control across everything tested at once; thin data self-suppresses through wide uncertainty rather than through magic thresholds. And every config edit is treated as a natural experiment (epoch-stamped, curves restarted), because a single-user, no-A/B design gets its causality nowhere else. Models run in shadow, scored on one-step-ahead prediction, and earn influence only by out-predicting the naive baseline — complexity lives here so the surfaced product can stay one sentence.

Test it passes: the user never sees a model, only `lodestar observations` (the plain printout that makes the store consentable) and, occasionally, one actionable line whose expected value has already paid for the interruption.

## The coach

The coach is the observation layer's voice: one priced, evidence backed suggestion at a time, offered at a moment the user can verify the claim from their own immediate experience. It is named the way the launcher and the graph are named — a register, never a persona. No first person, no praise, no mascot: advice is legitimate coming from a coach, and every step past the label toward a character raises social expectations a tool can only disappoint.

**The chip** rides the HUD's glass, never takes key focus, and captures nothing bare: its whole grammar lives on the lode key. Tap lode twice to accept — assent addressed to the instrument, structurally unable to collide with typing. Lode ⌫ answers "not this one". Ignoring it is the third answer: decay is "later", never a decline, so the chip carries no decision pressure. A missed offer parks in the menu as an inbox of at most one. Accepting writes exactly one config line through the same path ⌘K uses, so the file and the chip are the same source of truth — and anything that cannot be one config line stays in the report.

**When it speaks:** at navigation boundaries, because a navigation is the user declaring a context switch — the one moment interruption is nearly free. Suggestions whose evidence is a felt cost prefer their cue (the bind offer lands seconds after the search it would remove), but a cue is a scheduling preference, never a permission: a suggestion with no cue, or whose cue does not come within days, goes out at any quiet boundary. Vetoes are absolute — a live camera, an open bar, a chain in flight all silence it.

**The curriculum** is the object being optimized, not any single suggestion: one learning habit at a time, and the next releases when the current one's curve bends, not when a calendar says so. Pace is gated by demonstrated capacity — progressive overload — so the motivated compound quickly and a slow month is not nagged through. Declines are graded and none is forever: "later" retries at later moments then parks, "never" sleeps for a season, and both reopen when the evidence materially outgrows the answer, because the data kept moving. Every answer feeds the curriculum's own calibration; the coach's response to no is to get better, not louder.

Test it passes: the gesture is fixed (tap lode twice, always assent, no offer means no-op), and each appearance is rare enough to mean something — silence remains the resting state.

## Open questions (resolve by prototype, not reasoning)

- **Window-identity stability** across close/reopen for the specific apps in use. The probe answers this.
- **Namespace reservation**: `M`, `B`, and the digits are reserved as first characters (marks, breaths, index — marks and breaths since moved off letters entirely). Apps whose natural first letter is one of these need another path in the graph. Note in particular that Brave (`lode B ...`) currently collides with the breath prefix; one of them moves.
- **Launcher windows vs apps**: whether the launcher surfaces individual windows (v2).
- **Index `0`**: what, if anything, it does.
- **Naming the register**: "link" is the plain word, deliberately not Raycast's "quicklink". Whether a distinctive noun (beacon, waypoint) earns a config migration is unresolved; the plain word ships until it does.
- **Noticing what you keep typing** — resolved in the observation layer's favor: hosts are counted, locally and bounded, and a host that always lands in one profile becomes a _route recommendation_ rather than a hint chip. The chip question (where such a nudge appears in the UI) stays open; the data question is settled.
- **The retrospective**: the coach's slow mirror — a quarterly, offered-not-shoved look back at what the hands learned and the minutes returned, Wrapped-shaped, in glass and the house voice. Waits on a quarter of ledger existing to speak from; the per-suggestion closure receipt was considered and rejected (transactional framing crowds out the quiet transformation the product is for).
