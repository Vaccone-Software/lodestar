# Lodestar

**Everything one key away**

Free tools that make your Mac second nature: Write, Switch, Keep and Speak.
[lodestar.vaccone.software](https://lodestar.vaccone.software)

<!-- TODO: demo GIF. Ten seconds of one door working. -->

- **Write**: spelling and grammar checked as you type, in every app. A thin
  line under what reads wrong, fixed with a click, or with `lode ⇥` and a
  letter. Checked on your Mac.
- **Switch**: `lode space` opens any app, filling the screen, and `lode S` goes
  straight to Slack once S is its letter. Breaths (`lode ' W`) bring back whole
  layouts, relaunching what is not running.
- **Keep**: everything you copy, on `⇧⌘V`. A letter pastes, `/` searches, and a
  clip that is a color, a time or a measurement arrives read.
- **Speak**: `lode .` opens the draft. Talk and type into one cursor, edit with
  Vim keys, and `⏎` puts it where your cursor was. Turned into text on this
  Mac, and no audio is kept.

The first launch asks which one you came for and walks you through it. The
rest arrive later, one lesson at a time, when they would help.

Underneath all four is one grammar on one key. Lode is your right ⌘: hold it,
press a letter, and you are there. The same key reaches click hints
(`lode ;`), scroll mode (``lode ` ``), menu search (`lode -`) and Ask
(`lode ⏎`), which routes each web destination to the right browser profile.
Learn it once and your hands know it everywhere. SIP stays on. Spaces stay
untouched. One private API call, [documented](FINDINGS.md).

## Install

Requires a Mac with Apple silicon and macOS 14 or later. Best on macOS 26.

[Download it from the website](https://lodestar.vaccone.software), or with
Homebrew:

```sh
brew install --cask vaccone-software/tap/lodestar
```

Lodestar asks for one permission, Accessibility, and continues the moment the
grant lands. Lode is right ⌘ by default, which means right ⌘ stops being a
command key. That is the trade, and it is configurable.

From source:

```sh
git clone https://github.com/Vaccone-Software/lodestar.git && cd lodestar
./scripts/install-app.sh
```

## Learn it

- Hold **lode** alone: the system teaches its own map.
- **`lode ?`**: the cheat sheet. Every gesture, your live graph and breaths,
  generated from your actual config.
- [GUIDE.md](GUIDE.md): the complete reference.
- [DESIGN.md](DESIGN.md): the philosophy. Every feature must become a fixed
  gesture the hand owns, or it is cut.
- [FINDINGS.md](FINDINGS.md): the engineering ledger. Every platform
  assumption probed, with verdicts.

Your config is one sparse JSON file: it holds only what you changed, the
schema documents every option with editor completion, and every write is
validated against your machine with ground truth (`lodestar check`,
`lodestar config set`). Agents and tools get a stable contract:
[AGENTS.md](AGENTS.md).

## Governance

Lodestar is an opinionated instrument, built and maintained by one person at
Vaccone. The design carries deliberate opinions, and the reasoning usually
exists in [DESIGN.md](DESIGN.md) or [FINDINGS.md](FINDINGS.md) before a
decision looks wrong. Issues are very welcome: start them with `lodestar
diagnose` output so they begin with evidence, and keep them respectful and
succinct.

## Development

```sh
swift build && ./scripts/test.sh   # the whole suite, sharded, about 20 s
```

The gesture grammar, layout engine, and state stores are pure and tested in
`LodestarCore`. The app target is a thin AppKit shell. Once installed,
`lodestar diagnose`, `reload`, `reset-config`, and friends work from any
shell.

### The mark

The mark is defined once, in `Sources/LodestarCore/Mark.swift`, and every
copy is drawn from it: the menu bar at runtime, and the app icon, the disk
image and the website's assets by script. Its color is a parameter.

```sh
./scripts/make-icon.sh                     # International Orange, into .build/mark/
./scripts/make-icon.sh --accent '#0A84FF'  # any color, by hex
./scripts/make-icon.sh --preset green      # a named color (Mark.presets)
./scripts/make-icon.sh --all               # every preset, one folder each
./scripts/make-icon.sh --install           # the shipped color, into packaging/
                                           # and the site checkout
```

Each run writes the `.icns` and its iconset, a 1024 preview, the favicon
(`icon.svg`), the bare mark (`mark.svg`) and the faces with their fills
(`mark.json`). Changing the mark means changing `Mark.swift`; `MarkTests`
pins it so that is a decision, not an accident. DESIGN.md, "The mark", has
the reasoning.

## License

[FSL 1.1 with an MIT future grant](LICENSE.md). Fair Source: read it, audit
it, modify it for yourself. Do not ship a competing substitute. Each release
becomes MIT two years after it ships.
