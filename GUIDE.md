# Lodestar — the reference

Lode is **right ⌘** (configurable in `~/.config/lodestar/lodestar.json`).

## Gestures

| Gesture                        | Meaning                                                                      |
| ------------------------------ | ---------------------------------------------------------------------------- |
| `lode space`                   | Launcher — type, `↵` focus-or-launch maximized, `⇧↵` beside                  |
| `lode` + letter chain          | Graph: walk to an app (`S`=Slack … `E O`=Outlook, `W W`=Brave·Work)          |
| `⇧` on a graph/launcher summon | Beside me (equal split) instead of maximized                                 |
| `lode 1…8`                     | Jump to window by position (left→right, top→bottom)                          |
| `lode 9`                       | Always the last window                                                       |
| `lode O`                       | Flip layout horizontal ↔ vertical                                            |
| `lode '` + letters             | Breaths: letter(s) restore a saved layout                                    |
| `lode '` + `⇧letter`           | Save the current layout at that path                                         |
| `lode ' '`                     | Update the latest breath to the current layout                               |
| `lode Tab`                     | Window chooser for the focused app (filter by title, `↵` summon)             |
| `Tab` on a launcher app row    | Expand a running app into its windows                                        |
| `lode ⏎`                       | Ask: links · domains · search, each routed to its profile                    |
| `⌘K` in the launcher / Ask     | Add to graph · add a link · route a host or search — written into the config |
| `lode .`                       | Menu search: the frontmost app's menus, fuzzy, `↵` executes                  |
| `lode ,`                       | Scroll mode: `j/k` `h/l` · `d/u` half-page · `gg`/`⇧G` ends · `⇥` panes      |
| `lode ;` / `lode ⇧;`           | Click hints on the focused window — `⇧;` chains clicks (sticky)              |
| `lode [` / `lode ]`            | Move the focused window to the prev/next display (`⇧` = arrive beside)       |
| `lode Z` / `lode ⇧Z`           | Undo / redo the layout (summons, besides, flips, breaths)                    |
| `lode X` / `lode ⇧X`           | Back / forward — walk the attention timeline (previous destinations)         |
| `lode ⇧1…9`                    | Slide the focused window to that position (insert-and-shift, 9 = last)       |
| `lode 0` / `lode ⇧0`           | The focused window fills the display, rest parked — `⇧0` joins beside        |
| `⌫` inside breaths             | Arm delete — the next path typed is deleted, not visited                     |
| hold `lode` alone              | Peek: the graph guide + index badges over each layout window                 |
| `⇧⌘V`                          | Clipboard: cards on screen, a letter pastes — see below                      |
| `lode ?`                       | The cheat sheet — every gesture, your live graph and breaths                 |
| `esc`                          | Clear an active chain                                                        |

## Chains are sticky, on purpose

Once a traversal starts (`lode W`, `` lode ` ``, …) it waits **indefinitely** — the gesture is identical whether you finish it in 80ms or after a phone call. The glass guide panel stays on screen the whole time showing your prefix and every legal continuation (with app icons); a wrong letter keeps you in place with a note rather than ejecting you. Only a completion or `esc` ends the chain. While a chain is active, stray keystrokes are swallowed (they never leak into the focused app). And holding lode by itself for half a second peeks the top-level guide — the system teaches its own map.

## Launcher ranking & teaching

Results are ranked by fuzzy match quality **plus frecency** — every summon (graph, launcher) counts toward the app's score, decayed by recency. An empty query shows the things you actually go to, most-used first. Rows carry teaching chips: an app with a graph address shows it (`E P` on Proton Mail), a running app with several windows shows `⇥ 3` (Tab expands it) — every search is a flashcard for the faster gesture. The window chooser lists most-recently-focused first, with the window you're already in last; `esc` walks back to apps when you arrived via Tab. Row views are cached — typing repaints, never rebuilds. Guide columns adapt to your screen (a laptop gets two, a big display three or four), and flashes wear the icon of the app they acted on.

## Breath mechanics

- Bound paths are prefix-free automatically (a path resolves the instant it matches, so nothing deeper can ever be created past it — and binding a prefix of an existing path is refused as shadowing).
- `⇧letter` on an existing path overwrites that snapshot.
- Delete is verb-before-noun: `⌫` inside the chain arms deletion (the guide shows it), then the path you type is deleted instead of visited. `⌫` again disarms.

## Multiple monitors

**Every monitor owns its own layout** — members, orientation, digit indexes. Your verbs act on the _active_ display: **the one under the pointer** by default, so where your mouse rests is where summons land and panels appear (`app.active-display: focus` switches to the keyboard-focus display instead). Summons follow **visit-don't-pull**: a target already visible on _another_ monitor is focused where it lives (its arrangement untouched); anything hidden, parked, or freshly launched materializes on the screen you're using; on the _same_ monitor, a plain summon still goes maximized as always. `lode [`/`]` throw the focused window to the neighboring display (physical order, wrapping) — plain arrives maximized there, `⇧` arrives beside. Undo is one global timeline across displays; breaths capture the whole multi-display world and restore members to their original monitors (or the active one if that monitor is unplugged); peek badges index the active display.

**Docking just works.** Unplug a monitor and its members quietly park — the surviving display's arrangement is untouched — while the departed arrangement is remembered by the monitor's hardware identity (not its session ID, which macOS can reassign). Plug the same monitor back in and the arrangement returns exactly, minus anything you deliberately re-placed while undocked: your placement always wins, a world-moved-on guard. The memory is per-session on purpose — a Lodestar restart while undocked starts fresh, and breaths are how you bring back a world deliberately.

## Windows you did not summon

**They are left alone.** A window born outside Lodestar — a launcher, the Dock, `⌘N`, a certificate prompt, a file reveal — floats untouched above your layout, exactly as macOS would have it, and never hides what you were reading. System and accessibility floaters (notch apps, Control Center, overlay slivers) belong to accessory processes the model never even tracks.

**`lode 0` makes the focused window fill the display** when you want it managed: the summon treatment on demand, everything already in the layout parked, `⇧0` to join beside instead. It also **enrols** the window, so from then on it answers to `lode 1…9`, breaths, orientation flips, and `lode Z` like anything Lodestar summoned. That is the only way an unmanaged window becomes managed — Lodestar never decides on its own that a new window is a destination, and nothing is ever parked except what a placement displaced.

## The clipboard

`⇧⌘V` opens the paste strip: **recents along the bottom** labelled by the home row, left to right, and **pins climbing the left edge** numbered 1 to 5. Both of the things you are most likely to want — a pin, or what you just copied — sit at the same corner, so there is one place to look.

- **A letter pastes it as plain text.** Most pasting is unformatted and that is the good default.
- **`⇧letter` pastes it as copied** — rich text, HTML, or whatever proprietary flavour the source app offered. An image has no plain form, so both paste the image.
- **`⌘letter` opens that card's actions**: pin or unpin, delete, save an image to Downloads, or never save from that app again.
- **`1`…`5` reach the pins.** Slots are permanent: a new pin takes the lowest free one, and unpinning leaves a hole rather than renumbering the others, so a pin you have learned never moves. Empty slots still draw, so the numbers are always visible.
- **`/` searches**, `↵` pastes the match, `esc` steps back to the strip. A second `esc` closes.
- Any lode gesture exits and executes, the same as scroll and hints.

Pasting sets your system clipboard, so plain `⌘V` repeats it. What it never does is **reorder the list** — copies reorder, pastes do not, so the strip stays your copy history and the positions hold still while you use them.

**What is never recorded**: anything a password manager marks concealed, transient, or auto-generated; anything from an app in `clipboard.exclude-apps`; and anything containing a substring in `clipboard.exclude` — which is how you keep a reel you are forwarding out of your history without banning your browser. History lives in `~/.local/share/lodestar/clipboard`, never in `~/.config`, because that directory ends up in dotfiles repositories. It is excluded from backups and readable only by you. `clipboard.max-size-mb` decides how far back it reaches; pins are never trimmed. `lodestar clipboard clear` erases it.

In a password field macOS blocks synthetic keystrokes outright, so Lodestar puts the clip on the clipboard and tells you to press `⌘V` yourself rather than failing silently.

## Scroll mode

`lode ,` toggles it (Escape closes too). Entry always warps the pointer to the focused window's primary scroll pane — the same gesture scrolls the same thing every time — and `⇥` cycles between discovered panes (sidebar ↔ content), warping to each. **Holding `j/k/h/l` scrolls at constant velocity and stops the instant you release** (`scroll.smooth`, with `scroll.speed` px/s; turn smooth off for classic one-step-per-repeat with `scroll.step`). `gg`/`⇧G` jump by setting the pane's scrollbar value directly — instant and app-independent — with `gg` a true two-tap, no timeout. Polarity follows your system natural-scrolling preference automatically. Scroll mode is a lens, not a transaction: **any other lode verb exits and executes immediately** (`lode S` mid-scroll just takes you to Slack); plain typing is swallowed while the mode is on.

## Click hints

`lode ;` labels every pressable element of the focused window — buttons, links, checkboxes, popups, text inputs — with letters from your own alphabet (`hints.letters`, home row by default; singles while they suffice, uniform two-letter labels beyond, never a mix, so no label can fire while another remains reachable). **Type a label to press it; `⇧label` right-clicks it** (the element's own context-menu action when it has one, a synthetic right-click at its center otherwise); labels on text inputs focus them. Typing narrows — matching chips stay with your prefix accented, the rest vanish; `⌫` untypes.

`lode ⇧;` is the **chain-click lens**: every pick clicks and then the window is re-scanned and relabeled after a beat (`hints.rescan-delay`), so a click that changed the app — opened a panel, revealed a menu — gets fresh labels. Filling a form or clicking through a wizard never leaves the mode. Same exit rules as scroll: `esc` (or `lode ;` again) closes, any other lode verb exits and executes.

The harvest is asynchronous and bounded — a heavy Chromium page can never stall the overlay — and Electron apps get `AXManualAccessibility` woken automatically. Rows and table cells are deliberately unlabeled: they explode label counts and rarely beat scrolling.

## Ask

`lode ⏎` — a second bar with its own grammar: everything typed here is a destination on the web. **Links** (`web.links`) are named sites, optionally pinned to a profile — type `yt`, hit `↵`, land in YouTube in your Google profile. **Bare domains** (anything with a dot) route by `web.routes` — case-insensitive substring patterns, longest match wins — so `app.acme.dev` opens in your Work profile without being listed anywhere. **Anything else is a web search** (`web.search-url`), and routes apply to queries too: searching "acme deploy" lands in the Work profile. Unrouted input opens in `web.fallback` — `most-recent` (the profile of your most recently focused browser window) or a pinned profile. Every row wears the profile it will open in as a chip; `⇧↵` opens beside. Chromium family (Brave, Chrome, Edge) for now.

**`⌘K` promotes the row you are looking at**, the way the launcher's `⌘K` promotes an app into the graph. The row decides what is on offer, and the two promotions answer different questions — _this site, by this name_ and _every link like this one, from anywhere_:

- **`a` Add link** (bare-domain rows) — the card opens with a name prefilled from the host (`youtube.com` → `youtube`); type to replace it, `↵` writes it into `web.links`.
- **`r` Route this host** (domain and link rows) — the pattern is prefilled with the whole host and the profile is seeded with wherever that destination already goes. `↵` writes it into `web.routes`, and from then on anything matching that pattern lands in that profile: paste a friend's `x.com` link and it opens in Personal, not Work.
- **`r` Route this search** (search rows) — routes match _what you typed_, not just hosts, so a search is something to route even though it is nothing to name. The pattern is prefilled with the query's first word (`acme deploy` → `acme`), since the whole phrase as a pattern would match almost nothing. A search row is the one place `⌘K` offers no link: there is no site to point a name at, and the card says so.
- **`d` Remove link** (link rows) — takes it back out; the emptied table is pruned rather than left as a husk.

The profile is a **row inside the card** — its label, its current value, and `⇥` sitting where every other key sits — rather than a hint in the footer, so it looks like the control it is. `⇥` opens a second card, one column further out, listing the profile registry on digits. For a link, `0` leaves it **unpinned** — the default and usually the right answer: an unpinned link carries no `profile` key at all, so it keeps resolving through your routes and fallback instead of freezing today's answer into the file. A route has no `0`, because a route has to name a profile.

The card always says _why_ a destination opens where it does — `opens in Work · pinned`, `· matched acme`, `· fallback`, `· most recent browser` — so an inferred answer is never mistaken for one you chose. You never type a scheme (`https://` for the web, `http://` for a dev server — see below), and a name or pattern already in use is refused with what it points at rather than overwritten. The new row appearing in the bar, wearing its profile, is the receipt.

**Dev servers are destinations, not searches.** `localhost:3000`, `box.local`, `app.test/login`, `192.168.1.5:8080` all resolve as places to go — a port counts the same as a dot — and they open over `http://`, because a machine on your desk has no certificate and `https` would be the one guess that could never work. Loopback, `.local`/`.localhost`/`.test`/`.internal`, and the private IPv4 ranges get that treatment; everything else is still the web. An explicit scheme is never second-guessed.

## Links clicked in other apps

Routes only help where Lodestar is asked, which is the half of the problem that needs it least: when you type into the bar you already have the chance to choose. The clicked link is the case where you have none. So Lodestar can stand as the http handler and apply the same `web.routes` to links clicked anywhere — a friend's `x.com` link opening in Personal rather than whatever profile happened to be frontmost.

**Nothing changes until you choose it.** The menu bar offers _Route Clicked Links Through Lodestar_; it records whatever your default browser is right now, asks macOS to hand over the role (macOS puts up its own confirmation panel — that is the real gate), and remembers both. The same item then reads _Give Links Back to Brave_ and puts it back.

**The point is invisibility.** A link that matches no rule goes to your saved browser, untouched, brought forward exactly as a click always did: no rewriting of the URL, no `web.fallback`, no most-recent-profile guessing, and **no placement** — a link someone sent you is not a request to rearrange your layout. Only a matched rule diverts, and only then is a profile launch paid for. Measured cost of the decision itself is about 20µs; the budget for the whole hop is invisibility, and it is a tested ceiling rather than a hope.

**It fails safe, deliberately.** `web.clicks.enabled: false` while still registered makes Lodestar a transparent pass-through, so the off switch works from a text file without a trip through System Settings. A rule naming a deleted profile passes through rather than stranding the link. Uninstalling restores your saved browser before removing the app. And while Lodestar holds the role, an auto-update has to prove its router answers before the watchdog blesses it — booting is not enough when every link on the machine depends on you.

`web.clicks.trace: true` logs the host and chosen profile while you chase something. Off by default, host never URL: the log is paste-able, and where you go is not diagnostics.

Profiles live in a registry (`profiles.brave`, `profiles.chrome`, `profiles.edge`): Lodestar name → the browser's profile name, with keys global across browsers and referenced everywhere else (`brave:work` or `chrome:work` in the graph, `profile: work` in links). References are validated at Reload Config, and the registry itself is checked against each browser's real profile list — a renamed browser profile surfaces as one flagged line, not a mystery failure later.

## What Lodestar notices

Lodestar watches how you reach things, on this machine only, so it can tell you something useful about it. `observations.enabled` turns it off, and off means nothing is recorded and no file is written.

The rule is **how you got places, never what you were doing there**. It records the pauses inside an address, whether the map was consulted, chains abandoned and the key the hand pressed instead, which road reached an app and what that road cost in seconds, which app tends to follow which, and the host a destination opened at — the routing fact, so a repeated habit can become one config line. It never records a window title, a URL's path or query, a clipboard, or what you typed into the launcher beyond its first two characters. Everything lives in `~/.local/share/lodestar/` — `events.jsonl`, a rolling ninety days of raw material, and `observations.json`, the running summary that outlives it — deliberately not in `~/.config`, which is what people commit to dotfiles repositories. Nothing ever leaves the machine.

Two measurements still do most of the work, and neither needs to guess at what you would have done otherwise. **Pauses**: an address you own is typed at motor speed, one you are reconstructing has a gap in it, which is as close to "has this become muscle memory" as you can get without asking. **Abandons**: a chain you started and escaped out of is unambiguous in a way a slow chain is not, because a slow chain might be a phone call. Anything over ten seconds is discarded rather than averaged, since chains wait indefinitely by design and one interruption would otherwise poison every number here.

`lodestar observations` prints all of it, plainly, because a store you cannot read is one you cannot consent to; `lodestar observations clear` deletes it. What the report is willing to conclude is gated twice: a finding must be probably worth more time than it costs — relearning included, priced from your own learning curves — and it must survive false-discovery control across everything else being tested. Silence stays the honest answer until then, which is most of the first weeks. `lodestar observations engine` shows the fitted models behind the verdicts, for eyes that want the working shown.

## Config (`lodestar.json`)

The config is sparse JSON: it holds only what differs from the defaults,
so the file reads as pure intent. Every option's documentation lives in
the schema (editors surface it as you type; `lodestar schema` prints it),
and every writer — a hand edit, ⌘K in the launcher or in Ask,
`lodestar config set` — converges on the same canonical bytes.

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

Nested letters are the trie; values are an app name or `<browser>:<registry key>` (`brave:work`, `chrome:work`). **Multi-letter keys are sugar**: `"eo": "Outlook"` binds the chain E → O without writing the nesting (any depth: `wgg` works); a multi-letter key whose prefix is already a destination is refused with a validation problem. **Double-taps** (the `double-tap` section) bind a modifier tapped twice alone — `"cmd": "scroll"` makes tap-tap-⌘ enter scroll mode — as additional triggers; every default gesture stays. **Disabling** (the `gestures` section) gives every gesture a named switch — `"scroll": false` frees its keys to pass through to the app, shift variants included. Reserved first letters: `O`, `Z`, `X`. Breaths live on `'`, vim's mark key for a saved position, so M is Messages and B is free to bind. Deleting a key restores its default; `lodestar config` prints the full effective picture. Menu bar → Reload Config applies edits and reports every validation problem.

**Migrating from 0.9.9 and earlier**: the first boot of 0.9.10 converts
`lodestar.yaml` to `lodestar.json` automatically — same settings, sparse
form — and leaves the yaml in place, inert, until a later release retires
it. A yaml that fails to parse is never converted.

**Shift always means something** (beside, bind). If a hyper key shim rewrites right ⌘, configure it to exclude shift from its output — Lodestar accepts both the raw right-⌘ device bit and the shim's `⌘⌃⌥` form.

## Controls & state

- Menu bar star: Check for Updates… · Report an Issue… · Edit Config… · Reveal Config in Finder · Reload Config · Open Log · Quit (quitting restores everything parked). Hide it with `app.show-menu-bar: false` — then picking **Lodestar** in the launcher reveals it for 60 seconds with the menu popped open, ready to use. (Hidden mode forgoes the chain-active star; the guide panel still shows every pending chain.) `kill -USR2 $(cat ~/.config/lodestar/lodestar.pid)` reloads the config from scripts.
- CLI: `lodestar check [--json]` validates the config (schema + referential + ground truth); `lodestar reload` applies it to the running instance; `lodestar config` prints the effective config, `config get <path>` one value, `config set <path> <value>` a validated write applied live, `config unset <path>` the way back to default; `lodestar diagnose` prints one paste-able report (version, instance, trust, displays, config, state, log tail); `lodestar schema` and `lodestar config-path` serve tools and agents — see AGENTS.md for the agent contract.
- `scripts/install-app.sh` — build, sign, and install `~/Applications/lodestar.app` with a login LaunchAgent, so Lodestar survives reboots. **First install**: grant the app Accessibility when it prompts (System Settings → Privacy & Security → Accessibility) — Lodestar wakes up on its own within seconds of the grant. Signed with your Apple Development identity, so the grant survives rebuilds.
- `scripts/dev-restart.sh` — rebuild + hot-swap (unloads the login agent so launchd doesn't fight the dev instance).
- State: `~/.local/share/lodestar/state.json` (breaths, parked frames, usage) — **versioned and self-defending**: every boot keeps a last-known-good `state.json.bak`; a corrupted file is quarantined with a timestamp, restored from backup, and announced in a flash — never silently reset. Old formats migrate on load. Log: `~/.local/share/lodestar/lodestar.log`. Config and the pid file stay in `~/.config/lodestar`; everything Lodestar accumulates lives in `~/.local/share/lodestar`, which is deliberate — `~/.config` is what people commit to dotfiles repositories. `kill -USR1 $(cat ~/.config/lodestar/lodestar.pid)` dumps diagnostics to the log.
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
- **Back (`lode X`)** pairs with undo: Z rewinds arrangements, X rewinds attention. History records every focus change (however it happened), back-jumps summon with the standard placement rules, a fresh navigation truncates the forward branch, and dead windows are skipped.
- Menu harvesting and scroll-pane discovery run off the main thread — a hung app can no longer freeze Lodestar's UI; the panel opens instantly and rows arrive when ready.
- **Logs are logfmt** (`15:04 INFO summon target=Slack candidates=[8688]`) — greppable and machine-parseable — rotating at 5MB with two predecessors kept (`.1`, `.2`), bounded ~15MB, history preserved.
