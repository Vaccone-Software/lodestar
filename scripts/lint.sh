#!/bin/bash
# Stoic's linter over Sources: the unsafe patterns Stoic names (a `try?`
# that drops an error, a clock read a test cannot pin, a timer no scope
# owns, an escape from the race checker with no reason) fail it.
#
#   scripts/lint.sh                lint; exit 1 on any finding not recorded
#   scripts/lint.sh --write-baseline
#                                  record today's findings and suppressions
#                                  in .stoic-lint-baseline.json, in a change
#                                  a reviewer sees
#
# The linter is built from the Stoic that Package.resolved pins, so its
# rules move with the library and never ahead of it. It is built apart, in
# .build/stoic-lint, with the Lint trait on: Lodestar's own package graph
# never takes swift-syntax (Stoic's plugin would put it in every build).
#
# Every `// stoic:allow(<rule>): <reason>` in Sources is recorded in the
# baseline, so a new escape fails the lint until a reviewer sees it land in
# the baseline's diff.
set -euo pipefail
cd "$(dirname "$0")/.."

baseline=.stoic-lint-baseline.json
scratch=.build/stoic-lint
checkout=.build/checkouts/stoic

# The checkout SwiftPM made for the pinned version.
if [[ ! -f "$checkout/Package.swift" ]]; then
    swift package resolve >/dev/null
fi
pinned=$(sed -n '/"identity" : "stoic"/,/}/s/.*"version" : "\(.*\)".*/\1/p' Package.resolved)
revision=$(sed -n '/"identity" : "stoic"/,/}/s/.*"revision" : "\(.*\)".*/\1/p' Package.resolved)
if [[ "$(git -C "$checkout" rev-parse HEAD 2>/dev/null)" != "$revision" ]]; then
    swift package resolve >/dev/null
fi
[[ "$(git -C "$checkout" rev-parse HEAD 2>/dev/null)" == "$revision" ]] \
    || { echo "✕ lint: the Stoic checkout is not the $pinned that Package.resolved pins ($revision)"; exit 2; }

# Built once per Stoic version: the stamp names the version it was built from.
tool="$scratch/release/stoic-lint"
if [[ ! -x "$tool" || "$(cat "$scratch/.version" 2>/dev/null)" != "$pinned" ]]; then
    echo "→ building stoic-lint $pinned (once per Stoic version)"
    swift build --package-path "$checkout" --scratch-path "$scratch" \
        --traits Lint --product stoic-lint -c release >/dev/null
    echo "$pinned" > "$scratch/.version"
fi

if [[ "${1:-}" == "--write-baseline" ]]; then
    exec "$tool" --write-baseline "$baseline" Sources
fi
if [[ -f "$baseline" ]]; then
    exec "$tool" --baseline "$baseline" Sources
fi
exec "$tool" Sources
