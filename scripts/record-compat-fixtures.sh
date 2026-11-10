#!/bin/bash
# Records a release's compatibility fixtures (Stoic design/32): what this
# build writes for each format a released build must still read, kept under
# Tests/LodestarCoreTests/Compatibility/<format>/<release>/ with the reader as
# `_schema.json`, to be committed with the release's tag. A later build then
# has to read every one of them, and the test that says so fails, naming the
# release and the path, when it cannot.
#
#   scripts/record-compat-fixtures.sh 0.54.23
#
# Run it from the release's own commit, before anything newer is merged: the
# samples are what that release writes. The release must be the one in
# Sources/LodestarCore/Version.swift (the config's header carries it), and a
# release already recorded is never rewritten: a file whose bytes differ is
# refused, and the run fails, as it also does when it writes anything, so a
# recording is never mistaken for a pass. A release that never shipped is
# recorded again by deleting its folders first.
set -euo pipefail
cd "$(dirname "$0")/.."

release="${1:-}"
if [[ -z "$release" ]]; then
    echo "usage: scripts/record-compat-fixtures.sh <release>   (for example 0.54.23)" >&2
    exit 64
fi

current=$(sed -n 's/.*public static let version = "\(.*\)".*/\1/p' Sources/LodestarCore/Version.swift | head -1)
if [[ "$release" != "$current" ]]; then
    echo "✕ record: $release is not the version this tree builds ($current); record from the release's own commit" >&2
    exit 65
fi

# The recording run fails by design when it wrote anything: that is the
# signal to commit the new files, not a failure to look into.
log=$(mktemp)
if STOIC_RECORD_COMPATIBILITY="$release" swift test --filter LodestarCoreTests.CompatibilityTests >"$log" 2>&1; then
    echo "→ nothing to record: every fixture for $release is already there"
    rm -f "$log"
    exit 0
fi
if grep -q "recorded [0-9]* file" "$log"; then
    grep -E "recorded [0-9]* file|already recorded" "$log" | sed 's/^.*error: //' | sort -u
    if grep -q "a released promise is not rewritten" "$log"; then
        rm -f "$log"
        echo "✕ record: a file already recorded for $release has other bytes, and is left as it was" >&2
        exit 1
    fi
    rm -f "$log"
    echo "→ commit them with the release: git add Tests/LodestarCoreTests/Compatibility && git commit"
    exit 0
fi
cat "$log" >&2
rm -f "$log"
echo "✕ record: the run failed for a reason other than recording; the log is above" >&2
exit 1
