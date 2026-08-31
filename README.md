# Lodestar

**Keyboard navigation for macOS. Destination over process.**

Lodestar navigates to the application you want without distraction. Anything
you open or focus through it arrives maximized and hides the others, and
everything else about your windows keeps working the way you are used to.
Applications you use constantly can be assigned a letter, or a short set of
letters, and opened directly without a list.

Its commands are designed to become muscle memory. Navigation that begins as a
deliberate sequence turns into a single practised gesture, until you are
choosing a destination rather than the steps that lead to it.

<!-- TODO: demo GIF. Thirty seconds of hands owning a machine. -->

- **`lode S`**: you are in Slack, maximized. Not launching, not arranging.
- **`lode space`**: the launcher, a list of your applications ordered by what
  you actually use, teaching the faster gesture for everything you pick.
- **`lode ' W`**: breaths. Saved layouts that restore whole worlds, even
  relaunching apps that are not running.
- **`lode ;`**: click hints. Every pressable element wears a label. Type the
  label to click it.
- **``lode ` ``** / **`lode -`** / **`lode ⏎`**: scroll mode, menu search,
  and Ask, which routes each destination to the right browser profile.
- **`lode .`**: the draft. Speak, type into the same cursor, and `⏎` pastes
  it where your cursor already was. On-device; nothing leaves the Mac.

One grammar spans applications, the inside of a window, the web, and what you
have copied. Learn it once. Your hands know it everywhere. SIP stays on. Spaces stay untouched.
One private API call, [documented](FINDINGS.md).

## Install

Requires macOS 13 or later. Best on macOS 26.

```sh
git clone https://github.com/Vaccone-Software/lodestar.git && cd lodestar
./scripts/install-app.sh
```

Grant Accessibility when prompted. Lodestar wakes on its own the moment the
grant lands. Lode is right ⌘ by default, which means right ⌘ stops being a
command key. That is the trade, and it is configurable.

Or with Homebrew:

```sh
brew install --cask vaccone-software/tap/lodestar
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
swift build && swift test    # 163 tests: grammar, layout, resilience, hints
```

The gesture grammar, layout engine, and state stores are pure and tested in
`LodestarCore`. The app target is a thin AppKit shell. Once installed,
`lodestar diagnose`, `reload`, `reset-config`, and friends work from any
shell.

## License

[FSL 1.1 with an MIT future grant](LICENSE.md). Fair Source: read it, audit
it, modify it for yourself. Do not ship a competing substitute. Each release
becomes MIT two years after it ships.
