# Slice 0 findings

Empirical results from the probe. Machine: macOS 26 (Tahoe), single 3008x1692 display, an incumbent window manager running (relevant — see below). Update this file as more runs land.

## 1. The private-call bridge: GREEN

`probe list` bridged 15/15 AX windows to `CGWindowID`s, and every ID cross-checked against the window server's own list (`CGWindowListCopyWindowInfo`). All three target apps bridge cleanly: Brave, Ghostty, Proton Mail — plus Electron (Claude, Asana, Slack, Compass) and Catalyst (Messages, Music) apps.

Stronger still: the incumbent window manager's own enumeration reports the **exact same IDs** for every window. It uses the same single private call, so this validates our binding against a reference implementation. Finder showed one phantom AX window that did not bridge (no real window behind it) — harmless, but enumeration must tolerate it.

## 2. Parking: works, but macOS clamps it to a sliver — AMENDS THE DESIGN

Tested against a throwaway accessory-policy window (unmanaged by the incumbent), moved externally via the probe — the exact production path. No window manager interference:

| asked (Quartz)            | got          | meaning                                                |
| ------------------------- | ------------ | ------------------------------------------------------ |
| (3136, 1820) — fully off  | (2968, 1660) | pulled back: ~40px kept reachable, title bar on-screen |
| (3006, 1690) — 2px sliver | (3006, 1660) | x accepted as asked; y clamped so the title bar stays  |
| (300, 300) — restore      | (300, 300)   | exact round-trip, ID unchanged throughout              |

Control: the same window moving **itself** via `setFrameOrigin` (in-process, no AX) and asking for fully off-screen landed at the identical clamped spot. On macOS 26 the clamp is AppKit/window-server policy for every path, not an AX quirk — no one gets fully off-screen.

**Conclusion:** fully-off-screen parking ("beyond the union of all display bounds", per DESIGN.md) is not achievable through the external AX path — AppKit constrains the frame. The achievable floor is a **corner sliver: 1px wide, title-bar-height tall**. This is exactly where the incumbent parks hidden windows in production (observed: every hidden window at x=3007 on this 3008-wide display, y leaving a ~52px strip), so the strategy is battle-tested at the 1px floor. Park spec becomes: bottom-right corner sliver, per-display (the union's corner may lie on no display in L-shaped multi-monitor arrangements — pick a real display's corner so the sliver cannot peek onto another monitor).

Identity through parking is solid: the `CGWindowID` never changed while parked or after restore, matching the incumbent's operating assumption.

Caveat discovered on the way: windows currently _managed by the incumbent_ snap back to their enforced positions within ~50ms of any external move (tested on Music). Any park testing on this machine must use unmanaged windows until Lodestar takes over.

## 3. Tab-hidden windows vanish from live AX enumeration

The incumbent's cached model tracks 8 Ghostty windows; live `kAXWindows` polling sees only 3. The other five are native-tab-backgrounded windows — real windows, absent from both AX enumeration and the CG on-screen list. **Consequence:** the resolver cannot re-enumerate on demand; it must observe windows as they appear (AX notifications) and keep elements cached — the cached-model lesson, now with a second reason (the first being hung-app stalls).

A tempting fallback died on inspection: "check the CG all-windows list to tell hidden from closed." Tab-hidden live windows do appear there — but so can long-dead ones. Ghostty holds **71** layer-0 window records server-side, including windows closed during testing (12368, 12376 stayed listed after closing), while Brave releases closed windows immediately (113 vanished). Whether a dead window lingers is app-dependent, so CG-all presence is not a liveness signal. The only truthful discriminator between _closed_ and _hidden_ is a cached AX element plus `kAXUIElementDestroyed` notifications. That makes the cached model mandatory for three independent reasons: hung-app stalls, tab-hidden invisibility, and closed-vs-hidden ambiguity.

## 4. Close/reopen identity churn: CONFIRMED for all three targets — slice 0 complete

Run, one app at a time, and close/reopen windows while it watches (⌘⇧T in Brave; quit-and-relaunch too):

```sh
.build/debug/probe watch Brave --seconds 60
.build/debug/probe watch Ghostty --seconds 60
.build/debug/probe watch Proton --seconds 60
```

Expected on macOS: closed windows return with fresh IDs (`CHURNED`), meaning marks/breaths survive a close only via best-effort re-matching — which DESIGN.md already treats as the fallback. Record each verdict line here.

- Brave: **CHURNED** (2026-08-08) — the Default-profile window closed as id 113 and reopened as id 12342, verified by before/after enumeration diff. No ID reuse.
- Ghostty: **CHURNED** (2026-08-08) — a created-then-closed tab (12368) and a created-then-closed window (12376) each got fresh IDs and never returned; all persistent windows kept their IDs throughout. Tab-switching during the watch made the backgrounded window vanish from AX and return with the **same** id — that is a reveal, not a reopen: identity survives tab-backgrounding (as safe an anchor as parking), but only a cached element can address a window while it is hidden. (The v1 watch mislabeled reveals as `REUSED … after close/reopen`; fixed to `BACK`.)
- Proton Mail: **CHURNED** (2026-08-08) — quit-and-relaunch: window 3455 (pid 28973) became 12390 (pid 60208). Process death also cleared its old server-side records.

**Slice 0 verdict, overall:** the green-light shape from DESIGN.md holds. Live windows — parked, minimized, hidden, or tab-backgrounded — keep stable `CGWindowID`s for the whole session, so marks and breaths can pin them with confidence. A close is a hard identity break in every target app, so cross-close and cross-restart persistence is best-effort re-matching (relaunch the parent app, reposition), exactly the fallback the design already specifies. Nothing demotes to session-only. Amendments carried forward: sliver parking (finding 2) and the mandatory cached-model resolver (finding 3).

Two side-observations from the same diff. First, window-server IDs are practically monotonic within a login session (12325 → 12335 → 12342 across three consecutively created windows), so a dead mark's ID can never silently alias to a different window later — staleness is cleanly detectable, which is what lets marks trigger best-effort re-matching safely. Second, a freshly opened Ghostty window (12335) was tab-backgrounded and invisible to live AX enumeration from the start while the incumbent's cached model still tracked it — finding 3 reconfirmed on fresh data.

## 5. Build-night findings (prototype E2E, incumbent manager off)

- **A hyper-key shim rewrites events before the tap sees them.** Right ⌘ + key arrived as canonical `⌘⌃⌥⇧` (0x1e0000) with the device bit stripped — a shim transforms it upstream (identity unconfirmed: two candidate remapping tools run on this machine, and neither shows the transformation by name in its settings). Which tap sees raw vs. transformed flags depends on tap-chain insertion order and is not stable across process restarts. Consequence: the trigger accepts both the raw right-⌘ device bit (0x0010) and the canonical form, and shift-as-beside is only readable on trigger forms that don't already contain shift (raw device bit, or ⌘⌃⌥ "meh"). `hyper.shim-includes-shift` in the config documents which world you're in.
- **The shim also presses a real shift key** during transformed events, so sampling physical shift state (`CGEventSource.keyState`) cannot rescue beside-detection either — measured true exactly during event handling, false at idle.
- **Synthetic events posted at `.cgSessionEventTap` bypassed the shim** (posted at `.cghidEventTap` they got transformed). That ordering quirk is what let the E2E suite exercise raw-flag semantics, including beside, while the shim stays active for physical keys.
- **App minimum sizes break equal tiling**: Music refuses heights under ~600px, so a 3-way vertical split overflows its slice. Tiling is best-effort against app minimums; the model records the achieved frame, not the requested one.
- **Brave snaps to preferred widths** (2994 on a 3008 request) — cosmetic, same best-effort story.
- **Per-app `kAXFocusedWindowChanged` fires for non-frontmost apps too.** Treating it as global focus mis-focused breath restores; global focus must be gated on the app actually being frontmost (fixed in the model — the notification still tracks the window, which is how tab-reveals self-heal in).
- **The assign-on-free chain grammar makes exact paths instant, which is right for going but means a bound path can never be re-typed for delete/rebind** — the Delete gesture is unreachable for existing paths. v2 needs a distinct delete/rebind gesture; v1 workaround is editing `state.json`.
- Full E2E battery passed against real apps: summon/park-on-replace, 2- and 3-way beside splits, index jumps, orientation flip, searcher launch with async placement, Brave profile targeting by title suffix, mark bind/summon/dead-relaunch-rebind, breath save/restore/`B B` update, close-retile.

## 6. Adoption transients (2026-08-08, live probe of the user's session)

The classic tiling failure mode we're avoiding: transient windows entering the layout, and their exit leaving a crater. Empirical results on the live machine:

- **Accessory/system floaters can never be adopted — they can't even be tracked.** The model attaches AX observers only to `activationPolicy == .regular` apps. A live inventory found every floating overlay (Alcove notch windows, Control Center modules, a Superhuman sidebar sliver at 35×1075) owned by accessory/system processes on non-normal window layers (5, 24, 25, ~2^31). Two independent walls: process policy and window layer.
- **Untitled transients of regular apps get tracked but declined.** Observed twice in one hour, unprompted: Brave spawned `track id=16199 ''` and Finder `track id=16233 ''` — neither adopted (subrole/size/tab-coincidence filters). Tracking without adopting is correct: if one later proves to be a real window, focus self-heal still knows it.
- **Finder reveal (Brave's "show download" mechanic, `open -R`) has two paths.** With a suitable Finder window open, Finder REUSES it — an existing tracked window raises, no creation event, no adoption, layout untouched. With none, Finder creates one — adopted full-screen like any external open.
- **Adoption is a transaction: close restores what was displaced.** Each adoption records the members it displaced; when the adopted window is destroyed and its display's layout holds nothing else (the user never moved on), the displaced members return, retiled and raised. Verified live: YouTube fullscreen → reveal adopted Finder over it → ⌘W → `adopt-restore` put the video back, end state byte-identical to the start. Any layout activity after the adoption (summon, move, undo) cancels the restore — the world stays as the user last shaped it.
- Dialogs proper (`AXDialog`, palettes, popovers) are subrole-filtered. The known residual: document-browser windows (TextEdit's "Open") report `AXStandardWindow` and adopt — with restore-on-close, the cost of a wrong adoption is now one ⌘W.
- **Sweep respected dialogs only by luck — fixed.** `hyper 0` parked every alive non-member window, which would have slivered a tracked `AXDialog` (password prompt, auth window) off-screen. Sweep now shares adoption's place-vs-event test (`Placement.isPlace`): dialogs, palettes, and popovers are never swept, never parked, never moved — they stay exactly where their app put them. Replace-parking was already safe (it parks displaced layout members only, and an event window is never a member).

## 7. AXEnhancedUserInterface animates AX window moves (2026-08-08)

The "summon slides up from the corner" report. When an assistive client (VoiceOver and similar AX tools) flips `AXEnhancedUserInterface` on an app, macOS ANIMATES that app's AX-driven frame changes — a parked window glides out of its bottom-right sliver instead of snapping. Measured on the live machine: Brave and Excel had the flag on (nothing else did); a park was 16 interpolated frames over ~220ms. "Sometimes" in the report = only flagged apps.

The fix, now load-bearing: `AXWindow`'s setters drop the flag for the duration of the mutation and restore it after, preserving assistive-tech semantics. Every frame mutation must funnel through `AXWindow` — `Parking` originally called `AX.set` directly and kept animating after the first fix. After routing: park and claim are each a single observed frame change. Residual macOS-owned animation we don't touch: the de-minimize genie for windows the user minimized themselves.
