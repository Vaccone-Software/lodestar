# Lodestar

**Keyboard navigation for macOS. Destination over process.**

Most window tools ask you to manage windows: arrange them, resize them, cycle
through them. Lodestar starts from a different premise. You never wanted to
manage windows. You wanted to be somewhere. So every gesture names a
destination, and the system takes you there: full screen, instantly, silently.

<!-- TODO: demo GIF. Thirty seconds of hands owning a machine. -->

- **`hyper S`**: you are in Slack. Not launching, not arranging. There.
- **`hyper space`**: a searcher that ranks by what you actually use and
  teaches the faster gesture for everything you pick.
- **`` hyper ` Q ``**: marks. Letter addresses for specific windows.
- **`hyper ' W`**: breaths. Saved layouts that restore whole worlds, even
  relaunching apps that are not running.
- **`hyper ;`**: click hints. Every pressable element wears a label. Type the
  label to click it.
- **`hyper ,`** / **`hyper .`** / **`hyper ⏎`**: scroll mode, menu search,
  and a web bar that routes each destination to the right browser profile.

One grammar spans launching, windows, the inside of apps, and the web. Learn
it once. Your hands know it everywhere. SIP stays on. Spaces stay untouched.
One private API call, [documented](FINDINGS.md).

## Install

Requires macOS 13 or later. Best on macOS 26.

```sh
git clone https://github.com/Vaccone-Software/lodestar.git && cd lodestar
./scripts/install-app.sh
```

Grant Accessibility when prompted. Lodestar wakes on its own the moment the
grant lands. Hyper is right ⌘ by default, which means right ⌘ stops being a
command key. That is the trade, and it is configurable.

Or with Homebrew:

```sh
brew install --cask vaccone-software/tap/lodestar
```

## Learn it

- Hold **hyper** alone: the system teaches its own map.
- **`hyper ?`**: the cheat sheet. Every gesture, your live graph, marks, and
  breaths, generated from your actual config.
- [GUIDE.md](GUIDE.md): the complete reference.
- [DESIGN.md](DESIGN.md): the philosophy. Every feature must become a fixed
  gesture the hand owns, or it is cut.
- [FINDINGS.md](FINDINGS.md): the engineering ledger. Every platform
  assumption probed, with verdicts.

Your config is one commented YAML file with schema backed editor completion,
validated against your machine with ground truth (`lodestar check`). Agents
and tools get a stable contract: [AGENTS.md](AGENTS.md).

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
