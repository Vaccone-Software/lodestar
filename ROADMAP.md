# Roadmap

The features agreed to, in priority order, with the design decisions that
were settled when each was discussed — so building one starts from the
argument, not from scratch. The changelog at the bottom is the ledger:
every release that moves an item here gets a line, appended at ship time.

The standing rules every item obeys: **no new bars** (every feature lands
in a surface that already exists — a chain, the chip, the sheet, the menu,
or one settings window), and DESIGN.md's gesture test (a fixed gesture the
hand owns, never a fresh decision at the moment of use).

## 1. Machine register _(parked — design agreed, key choice open)_

System commands as addresses, not pickers. One register on a non-letter
key (recommended `lode -`; `↑` the fallback), letters within, exactly the
breath grammar:

- **Audio output by letter** — `lode - A` → AirPods. Keyed on device UID,
  never device ID (the marks lesson: an address must survive the thing
  being gone). Letters drafted from device names, rebindable in config.
- **Caffeinate / decaffeinate** — a toggle must announce its resulting
  state: HUD flash on toggle, and one menu bar line while caffeinated
  (click releases). Gestures do, the menu shows.
- **Screensaver.**
- **Mic mute** — input volume to zero and back via CoreAudio.

Build order: probe first (UID stability, assertion lifecycle against
`pmset -g assertions`, input-volume round trip), then the register core
against the probe's verdicts. No new permissions. Deliberately not a
plugin system — extensions are ceded to Raycast on purpose; the moment
Lodestar hosts other people's commands it becomes a menu of fresh
decisions, the thing it exists to kill.

## 2. GUI settings on `lode ,`

The comma was freed in 0.20.0 (scroll moved to `` lode ` ``) and does
nothing until this exists — pointing it at the raw config file was
rejected as hostile to non-technical users. The pane:

- Hand-placed controls for the ~15 real preferences (lode trigger,
  gesture toggles, start at login, auto-update, clipboard, scroll feel,
  coach, meetings, browser profiles). Never the schema rendered as a form.
- A **permissions inventory** page: every permission the app holds or can
  hold, its state, and why — Accessibility, Screen Recording, Calendars,
  the browser role.
- One generated "everything else" section so nothing is unreachable.
- Writes through the same pruning path ⌘K uses, or the sparse config file
  stops being the thing people commit to dotfiles. The file and the UI
  stay one source of truth.

## 3. Monthly observations rollup _(urgent — data expires daily)_

`events.jsonl` keeps ninety rolling days, so any retrospective needs a
durable monthly summary written when a month closes: counts per app,
chain, host, and provider; latency quantiles; coach ledger outcomes.
Versioned, broad, and dumb on purpose — a write-time aggregate is
unavoidable when the source expires, so the discipline becomes keeping it
reinterpretable by models that do not exist yet. Small (~50 lines plus
tests). Prerequisite for item 4, and every day without it is Wrapped
data gone for good.

## 4. Wrapped — the quarterly retrospective

Per DESIGN.md: quarterly, offered never shoved, Wrapped-shaped, in glass
and the house voice. Waits on a quarter of ledger existing to speak from.
The per-suggestion closure receipt was considered and rejected. The
meeting ledger (joins at the door, deciders, lead deltas) feeds it.

## Settled policies (apply to everything above)

- Screen Recording and Calendars stay lazy, primed-then-prompted at the
  moment of use or enablement — never at install. Accessibility remains
  the only door ask.
- The lode-lode grammar has one floor: walk > meeting > coach. New voices
  join the order; they never share it.
- UI copy: no dashes or semicolons in prose, professional and direct, no
  surface ever on a clock. Release notes keep the house voice.

---

## Changelog

Appended at ship time, newest first, one entry per release that moves
this list.

### 2026-08-20 · v0.21.2 — meetings, hardened

Robustness pass on item "meetings" (shipped in 0.21.0): earliest link
wins within a field, Meet lookup and Zoom for Government recognized,
Teams classic joins natively beside the new client, encoded Zoom
passwords survive the transform, the calendar fetch left the main
thread, change notifications debounce, the grant walks in on its own
(the Accessibility no-relaunch promise, kept for calendars), and
`lodestar check` names the enabled-but-denied state.

### 2026-08-19 · v0.21.1 — the calendar prompt appears

The hardened runtime is a whitelist: 0.21.0 carried the purpose string
but not the entitlement, so macOS declined the calendar silently. The
signing lane now declares `com.apple.security.personal-information.calendars`.
Turning meetings off and on again re-shows the permission card.

### 2026-08-19 · v0.21.0 — meetings at the door

Formerly item "meeting join," pulled ahead of the machine register by
priority call. The chip (lead-minutes early, lives the meeting out,
spent by its own join, per-occurrence dismissal), calendar-beats-route
profile resolution with the decider worn on the chip, native Zoom and
Teams joins, the enable contract (menu and coach both write exactly
`meetings.enabled: true`; the subsystem reconciles intent with
authorization), and the coach's first feature offer — evidence from
meeting hosts and meeting-app focus already in the ledger, priced
against a declared prior, cued seconds after a manual join, retired
forever on enablement.

### 2026-08-19 · v0.20.0 — the tutorial watches your hands

Two items from the original discussion. The walk replaced the deck:
eight steps at most, each completed by the real gesture, on a card that
is never key; the door asks for the one permission and stays visible
beside System Settings; drafted letters offered when the graph is thin,
accepted with two taps of lode; no card on a clock; everyone saw it
once. And scroll moved to `` lode ` ``, freeing the comma for settings
before any muscle memory formed.
