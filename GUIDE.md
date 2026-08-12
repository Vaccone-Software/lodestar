# Lodestar — the reference

Hyper is **right ⌘** (configurable in `~/.config/lodestar/lodestar.json`).

## Gestures

| Gesture                        | Meaning                                                                 |
| ------------------------------ | ----------------------------------------------------------------------- |
| `hyper space`                  | Searcher — type, `↵` focus-or-launch full-screen, `⇧↵` beside           |
| `hyper` + letter chain         | Graph: walk to an app (`S`=Slack … `E O`=Outlook, `W W`=Brave·Work)     |
| `⇧` on a graph/searcher summon | Beside me (equal split) instead of full-screen                          |
| `hyper 1…8`                    | Jump to window by position (left→right, top→bottom)                     |
| `hyper 9`                      | Always the last window                                                  |
| `hyper O`                      | Flip layout horizontal ↔ vertical                                       |
| `` hyper ` `` + letters        | Marks (vim's goto-mark key): letter(s) navigate to a bound window       |
| `` hyper ` `` + `⇧letter`      | Bind (or rebind) that path to the focused window                        |
| `hyper '` + letters            | Breaths: letter(s) restore a saved layout                               |
| `hyper '` + `⇧letter`          | Save the current layout at that path                                    |
| `hyper ' '`                    | Update the latest breath to the current layout                          |
| `hyper Tab`                    | Window chooser for the focused app (filter by title, `↵` summon)        |
| `Tab` on a searcher app row    | Expand a running app into its windows                                   |
| `hyper ⏎`                      | Web bar: quick links · domains · search, each routed to its profile     |
| `hyper .`                      | Menu search: the frontmost app's menus, fuzzy, `↵` executes             |
| `hyper ,`                      | Scroll mode: `j/k` `h/l` · `d/u` half-page · `gg`/`⇧G` ends · `⇥` panes |
| `hyper ;` / `hyper ⇧;`         | Click hints on the focused window — `⇧;` chains clicks (sticky)         |
| `hyper =` / `hyper ⇧=`         | Claim the focused window: full screen, rest parked — `⇧=` joins beside  |
| `hyper [` / `hyper ]`          | Move the focused window to the prev/next display (`⇧` = arrive beside)  |
| `hyper Z` / `hyper ⇧Z`         | Undo / redo the layout (summons, besides, flips, breaths)               |
| `hyper X` / `hyper ⇧X`         | Back / forward — walk the attention timeline (previous destinations)    |
| `hyper ⇧1…9`                   | Slide the focused window to that position (insert-and-shift, 9 = last)  |
| `hyper 0`                      | Sweep: park every background window not in the layout (never dialogs)   |
| `⌫` inside marks/breaths       | Arm delete — the next path typed is deleted, not visited                |
| hold `hyper` alone             | Peek: the graph guide + index badges over each layout window            |
| `hyper ?`                      | The cheat sheet — every gesture, your live graph/marks/breaths          |
| `esc`                          | Clear an active chain                                                   |

## Chains are sticky, on purpose

Once a traversal starts (`hyper W`, `` hyper ` ``, …) it waits **indefinitely** — the gesture is identical whether you finish it in 80ms or after a phone call. The glass guide panel stays on screen the whole time showing your prefix and every legal continuation (with app icons); a wrong letter keeps you in place with a note rather than ejecting you. Only a completion or `esc` ends the chain. While a chain is active, stray keystrokes are swallowed (they never leak into the focused app). And holding hyper by itself for half a second peeks the top-level guide — the system teaches its own map.

## Searcher ranking & teaching

Results are ranked by fuzzy match quality **plus frecency** — every summon (graph, mark, searcher) counts toward the app's score, decayed by recency. An empty query shows the things you actually go to, most-used first. Rows carry teaching chips: an app with a graph address shows it (`E P` on Proton Mail), a running app with several windows shows `⇥ 3` (Tab expands it), and marked windows show their mark path (`◆ Q`) — every search is a flashcard for the faster gesture. The window chooser lists most-recently-focused first, with the window you're already in last; `esc` walks back to apps when you arrived via Tab. Row views are cached — typing repaints, never rebuilds. Guide columns adapt to your screen (a laptop gets two, a big display three or four), and flashes wear the icon of the app they acted on.

## Marks & breaths mechanics

- Bound paths are prefix-free automatically (a path resolves the instant it matches, so nothing deeper can ever be created past it — and binding a prefix of an existing path is refused as shadowing).
- `⇧letter` on an existing path **rebinds** it to the focused window (marks) or overwrites the snapshot (breaths).
- A mark whose window was closed re-matches best-effort (same app, closest title) or relaunches the app and rebinds itself.
- Delete is verb-before-noun: `⌫` inside the chain arms deletion (the guide shows it), then the path you type is deleted instead of visited. `⌫` again disarms.
- Marks summon plain (full-screen) — shift now means bind, so beside-summon for marks specifically is retired.

## Multiple monitors

**Every monitor owns its own layout** — members, orientation, digit indexes. Your verbs act on the _active_ display: **the one under the pointer** by default, so where your mouse rests is where summons land and panels appear (`app.active-display: focus` switches to the keyboard-focus display instead). Summons follow **visit-don't-pull**: a target already visible on _another_ monitor is focused where it lives (its arrangement untouched); anything hidden, parked, or freshly launched materializes on the screen you're using; on the _same_ monitor, a plain summon still goes full-screen as always. `hyper [`/`]` throw the focused window to the neighboring display (physical order, wrapping) — plain arrives full-screen there, `⇧` arrives beside. Undo is one global timeline across displays; sweep parks everything not in _any_ monitor's layout; breaths capture the whole multi-display world and restore members to their original monitors (or the active one if that monitor is unplugged); peek badges index the active display.

**Docking just works.** Unplug a monitor and its members quietly park — the surviving display's arrangement is untouched — while the departed arrangement is remembered by the monitor's hardware identity (not its session ID, which macOS can reassign). Plug the same monitor back in and the arrangement returns exactly, minus anything you deliberately re-placed while undocked: your placement always wins, the same world-moved-on guard adoption restore uses. The memory is per-session on purpose — a Lodestar restart while undocked starts fresh, and breaths are how you bring back a world deliberately.

## Adoption

**Windows you did not summon are left alone.** A window born outside Lodestar — a launcher, the Dock, `⌘N`, a certificate prompt, a file reveal — floats untouched above your layout, exactly as macOS would have it, and never hides what you were reading. For a stricter world, `app.adopt-new-windows: true` gives external windows the summon treatment instead: full screen on the active display, the rest parked. Either way, `hyper =` claims the focused window deliberately — the summon treatment on demand, `⇧=` to join beside. When adoption is on, only genuine destinations are adopted: dialogs, palettes, and popovers are excluded by AX subrole, tiny windows by size, and **native tabs are left alone** — a window materializing exactly atop a living sibling of the same app (Ghostty/Terminal/Finder tab created or revealed) is a tab, and adopting it would collapse the arrangement its host lives in. System and accessibility floaters (notch apps, Control Center, overlay slivers) belong to accessory processes the model never even tracks. Adoption never fires during Lodestar's own startup scan, and `hyper Z` undoes an adoption like any other layout change.

**Adoption, when enabled, is a transaction.** Each adoption remembers what it displaced; closing the adopted window brings those members back — retiled, raised — provided the layout hasn't changed since (any summon, move, or undo after the adoption means the world has moved on, and it stays as you shaped it). So a transient like Brave's "show download in Finder" costs nothing: the Finder window takes the screen, you look, `⌘W`, and your arrangement returns on its own. (When Finder reuses an existing window for a reveal, there's no creation at all — it just raises, floating, layout untouched.)

## Scroll mode

`hyper ,` toggles it (Escape closes too). Entry always warps the pointer to the focused window's primary scroll pane — the same gesture scrolls the same thing every time — and `⇥` cycles between discovered panes (sidebar ↔ content), warping to each. **Holding `j/k/h/l` scrolls at constant velocity and stops the instant you release** (`scroll.smooth`, with `scroll.speed` px/s; turn smooth off for classic one-step-per-repeat with `scroll.step`). `gg`/`⇧G` jump by setting the pane's scrollbar value directly — instant and app-independent — with `gg` a true two-tap, no timeout. Polarity follows your system natural-scrolling preference automatically. Scroll mode is a lens, not a transaction: **any other hyper verb exits and executes immediately** (`hyper S` mid-scroll just takes you to Slack); plain typing is swallowed while the mode is on.

## Click hints

`hyper ;` labels every pressable element of the focused window — buttons, links, checkboxes, popups, text inputs — with letters from your own alphabet (`hints.letters`, home row by default; singles while they suffice, uniform two-letter labels beyond, never a mix, so no label can fire while another remains reachable). **Type a label to press it; `⇧label` right-clicks it** (the element's own context-menu action when it has one, a synthetic right-click at its center otherwise); labels on text inputs focus them. Typing narrows — matching chips stay with your prefix accented, the rest vanish; `⌫` untypes.

`hyper ⇧;` is the **chain-click lens**: every pick clicks and then the window is re-scanned and relabeled after a beat (`hints.rescan-delay`), so a click that changed the app — opened a panel, revealed a menu — gets fresh labels. Filling a form or clicking through a wizard never leaves the mode. Same exit rules as scroll: `esc` (or `hyper ;` again) closes, any other hyper verb exits and executes.

The harvest is asynchronous and bounded — a heavy Chromium page can never stall the overlay — and Electron apps get `AXManualAccessibility` woken automatically. Rows and table cells are deliberately unlabeled: they explode label counts and rarely beat scrolling.

## The web bar

`hyper ⏎` — a second bar with its own grammar: everything typed here is a destination on the web. **Quick links** (`web.links`) are named sites pinned to a profile — type `yt`, hit `↵`, land in YouTube in your Google profile. **Bare domains** (anything with a dot) route by `web.routes` — case-insensitive substring patterns, longest match wins — so `app.acme.dev` opens in your Work profile without being listed anywhere. **Anything else is a web search** (`web.search-url`), and routes apply to queries too: searching "acme deploy" lands in the Work profile. Unrouted input opens in `web.fallback` — `most-recent` (the profile of your most recently focused browser window) or a pinned profile. Every row wears the profile it will open in as a chip; `⇧↵` opens beside. Chromium family (Brave, Chrome, Edge) for now.

Profiles live in a registry (`profiles.brave`, `profiles.chrome`, `profiles.edge`): Lodestar name → the browser's profile name, with keys global across browsers and referenced everywhere else (`brave:work` or `chrome:work` in the graph, `profile: work` in links). References are validated at Reload Config, and the registry itself is checked against each browser's real profile list — a renamed browser profile surfaces as one flagged line, not a mystery failure later.

## Config (`lodestar.json`)

The config is sparse JSON: it holds only what differs from the defaults,
so the file reads as pure intent. Every option's documentation lives in
the schema (editors surface it as you type; `lodestar schema` prints it),
and every writer — a hand edit, ⌘K in the searcher, `lodestar config set`
— converges on the same canonical bytes.

```json
{
  "$schema": "lodestar-schema.json",
  "version": "0.9.10",
  "profiles": {
    "brave": { "work": "Work", "google": "Google" }
  },
  "web": {
    "links": { "yt": { "url": "youtube.com", "profile": "google" } },
    "routes": { "acme": "work" }
  },
  "graph": {
    "s": "Slack",
    "e": { "o": "Microsoft Outlook", "p": "Proton Mail" },
    "w": { "w": "brave:work" }
  }
}
```

Nested letters are the trie; values are an app name or `<browser>:<registry key>` (`brave:work`, `chrome:work`). **Multi-letter keys are sugar**: `"eo": "Outlook"` binds the chain E → O without writing the nesting (any depth: `wgg` works); a multi-letter key whose prefix is already a destination is refused with a validation problem. **Double-taps** (the `double-tap` section) bind a modifier tapped twice alone — `"cmd": "scroll"` makes tap-tap-⌘ enter scroll mode — as additional triggers; every default gesture stays. **Disabling** (the `gestures` section) gives every gesture a named switch — `"scroll": false` frees its keys to pass through to the app, shift variants included. Reserved first letters: `O`, `Z`, `X`. Marks and breaths live on vim's two mark keys — `` ` `` for a saved window, `'` for a saved layout — so M is Messages and B is free to bind. Deleting a key restores its default; `lodestar config` prints the full effective picture. Menu bar → Reload Config applies edits and reports every validation problem.

**Migrating from 0.9.9 and earlier**: the first boot of 0.9.10 converts
`lodestar.yaml` to `lodestar.json` automatically — same settings, sparse
form — and leaves the yaml in place, inert, until a later release retires
it. A yaml that fails to parse is never converted.

**Shift always means something** (beside, bind). If a hyper key shim rewrites right ⌘, configure it to exclude shift from its output — Lodestar accepts both the raw right-⌘ device bit and the shim's `⌘⌃⌥` form.

## Controls & state

- Menu bar star: Check for Updates… · Report an Issue… · Edit Config… · Reveal Config in Finder · Reload Config · Open Log · Quit (quitting restores everything parked). Hide it with `app.show-menu-bar: false` — then picking **Lodestar** in the searcher reveals it for 60 seconds with the menu popped open, ready to use. (Hidden mode forgoes the chain-active star; the guide panel still shows every pending chain.) `kill -USR2 $(cat ~/.config/lodestar/lodestar.pid)` reloads the config from scripts.
- CLI: `lodestar check [--json]` validates the config (schema + referential + ground truth); `lodestar reload` applies it to the running instance; `lodestar config` prints the effective config, `config get <path>` one value, `config set <path> <value>` a validated write applied live, `config unset <path>` the way back to default; `lodestar diagnose` prints one paste-able report (version, instance, trust, displays, config, state, log tail); `lodestar schema` and `lodestar config-path` serve tools and agents — see AGENTS.md for the agent contract.
- `scripts/install-app.sh` — build, sign, and install `~/Applications/lodestar.app` with a login LaunchAgent, so Lodestar survives reboots. **First install**: grant the app Accessibility when it prompts (System Settings → Privacy & Security → Accessibility) — Lodestar wakes up on its own within seconds of the grant. Signed with your Apple Development identity, so the grant survives rebuilds.
- `scripts/dev-restart.sh` — rebuild + hot-swap (unloads the login agent so launchd doesn't fight the dev instance).
- State: `~/.config/lodestar/state.json` (marks, breaths, parked frames, usage) — **versioned and self-defending**: every boot keeps a last-known-good `state.json.bak`; a corrupted file is quarantined with a timestamp, restored from backup, and announced in a flash — never silently reset. Old formats migrate on load. Log: `lodestar.log`. `kill -USR1 $(cat ~/.config/lodestar/lodestar.pid)` dumps diagnostics to the log.
- Versions: the binary knows its version (`lodestar 0.9.0 starting` in the log, shown in the menu header), and both `state.json` and `lodestar.json` record the release that wrote them — schema changes migrate the file at boot, with the writing release always on record.

## Config DX

- **Every reload validates everything**: JSON syntax, unknown keys with "did you mean" hints, types/enums/ranges, registry references, the registry against each browser's real profile list, app names against what's installed, and unused profiles. Problems flash on screen and land in the log. `lodestar config set` refuses any write that would introduce a problem.
- **Editor intelligence for free**: the config's `$schema` key points at `lodestar-schema.json` (emitted beside the config, generated from the same Swift table that validates reloads — they cannot drift). VS Code natively, and any LSP-aware editor, gets completion, hover docs, and type checking.
- **`app.auto-reload: true`** watches the file and reloads the moment you save — your editor becomes the IDE because saving is validating. Off by default.
- **`app.start-at-login`** (default true) — the installed app installs or removes its own LaunchAgent to match; setting false never kills the running session, it just stops the next login from starting one. Dev builds never touch login items.
- **`app.auto-update`** (default true) — the installed app keeps itself current: a daily check, a background download, and a strict verification (signature integrity, this team's Developer ID, this bundle id, version matching the release) before anything moves. The swap waits for a quiet moment — no chain, no panel, ten minutes since the last gesture — hands the session over exactly like a manual reinstall, and a watchdog restores the previous version if the new one fails to boot. One flash afterward: quiet, never hidden. Menu bar → Check for Updates… checks and applies immediately. Dev builds never self-update.
- **`lodestar --check`** — full validation from the CLI, exit code included: `~/Applications/lodestar.app/Contents/MacOS/lodestar --check`.
- **`keys:`** overlays the built-in ANSI keycode table for non-ANSI layouts (`keycode: name`).
- **Crash self-healing**: the LaunchAgent restarts Lodestar after a crash (10s throttle) but never after a clean Quit.
- **Back (`hyper X`)** pairs with undo: Z rewinds arrangements, X rewinds attention. History records every focus change (however it happened), back-jumps summon with the standard placement rules, a fresh navigation truncates the forward branch, and dead windows are skipped.
- Menu harvesting and scroll-pane discovery run off the main thread — a hung app can no longer freeze Lodestar's UI; the panel opens instantly and rows arrive when ready.
- **Logs are logfmt** (`15:04 INFO summon target=Slack candidates=[8688]`) — greppable and machine-parseable — rotating at 5MB with two predecessors kept (`.1`, `.2`), bounded ~15MB, history preserved.
