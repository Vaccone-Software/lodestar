#!/bin/bash
# The whole suite, sharded: every test class runs, spread across a few
# xctest processes at once. Half a serial `swift test` is waiting — run
# loops, timers, WindowServer — so overlapping it pays: about 50 s becomes
# about 12 s on an M1 Max, with the same CPU.
#
#   scripts/test.sh              six app shards plus the core bundle
#   TEST_SHARDS=8 scripts/test.sh
#
# Not `swift test --parallel`: that spawns one process per test, each
# reloading AppKit, and measured slower than serial. Not concurrent
# `swift test --filter` either: they would fight over the .build lock.
#
# Classes are balanced by the time each took last run (.build/test-timings.txt,
# rewritten after every run; a class with no timing yet goes to the lightest
# shard). A shard that runs no tests fails the run: a bad -XCTest name runs
# nothing and exits 0. So does a total that does not match the test list.
set -uo pipefail
cd "$(dirname "$0")/.."

SHARDS=${TEST_SHARDS:-6}
OUT=.build/test-shards
TIMINGS=.build/test-timings.txt
started=$(date +%s)

if ! build=$(swift build --build-tests 2>&1); then
    echo "$build" | grep -E "error|warning: unreachable" | head -40
    echo "✕ the tests do not build"
    exit 1
fi
BIN=$(swift build --show-bin-path)
# One bundle per test target (Xcode 27's SwiftPM), or every target in one
# lodestarPackageTests.xctest (older toolchains, CI's runner among them).
# Test names are Bundle.Class either way, so -XCTest filters the same.
APP_BUNDLE="$BIN/LodestarAppTests.xctest"
CORE_BUNDLE="$BIN/LodestarCoreTests.xctest"
if [ ! -d "$APP_BUNDLE" ]; then
    ONE=$(ls -d "$BIN"/*PackageTests.xctest 2>/dev/null | head -1)
    APP_BUNDLE="$ONE"
    CORE_BUNDLE="$ONE"
fi
if [ ! -d "$APP_BUNDLE" ] || [ ! -d "$CORE_BUNDLE" ]; then
    echo "✕ no test bundles in $BIN"
    ls "$BIN" | grep -i xctest
    exit 1
fi

rm -rf "$OUT"
mkdir -p "$OUT"
swift test list --skip-build 2>/dev/null > "$OUT/tests.txt"
expected=$(wc -l < "$OUT/tests.txt" | tr -d ' ')
if [ "$expected" -eq 0 ]; then
    echo "✕ no tests found"
    exit 1
fi

# LPT: the slowest class first, each onto the lightest shard. The core
# bundle is a few seconds in all, so it is one shard of its own.
python3 - "$OUT/tests.txt" "$TIMINGS" "$SHARDS" "$OUT" <<'PY'
import sys, heapq, os
tests, timings, n, out = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]
classes = sorted({line.strip().split("/")[0] for line in open(tests) if "/" in line})
known = {}
if os.path.exists(timings):
    for line in open(timings):
        seconds, name = line.split()
        known[name] = float(seconds)
app = [c for c in classes if c.startswith("LodestarAppTests.")]
core = [c for c in classes if c.startswith("LodestarCoreTests.")]
heap = [(0.0, i, []) for i in range(n)]
for c in sorted(app, key=lambda c: -known.get(c, 0.0)):
    load, i, members = heapq.heappop(heap)
    members.append(c)
    heapq.heappush(heap, (load + known.get(c, 0.5), i, members))
for load, i, members in heap:
    if members:
        open(f"{out}/app{i}.list", "w").write(",".join(members))
open(f"{out}/core.list", "w").write(",".join(core))
PY

pids=()
logs=()
for list in "$OUT"/app*.list "$OUT/core.list"; do
    name=$(basename "$list" .list)
    bundle="$APP_BUNDLE"
    [ "$name" = core ] && bundle="$CORE_BUNDLE"
    xcrun xctest -XCTest "$(cat "$list")" "$bundle" > "$OUT/$name.log" 2>&1 &
    pids+=($!)
    logs+=("$OUT/$name.log")
done

failed=0
for index in "${!pids[@]}"; do
    wait "${pids[$index]}" || failed=1
done

executed=0
for log in "${logs[@]}"; do
    # The bundle's own summary: the last "Executed N tests" line.
    count=$(grep -E "^\s+Executed [0-9]+ tests?" "$log" | tail -1 | sed -E 's/.*Executed ([0-9]+) test.*/\1/')
    if [ -z "$count" ] || [ "$count" -eq 0 ]; then
        echo "✕ $(basename "$log" .log) ran no tests"
        tail -5 "$log"
        failed=1
    else
        executed=$((executed + count))
    fi
done

# Next run's balance: seconds per class, summed from every test line.
cat "${logs[@]}" | python3 -c '
import re, sys, collections
seconds = collections.Counter()
for line in sys.stdin:
    m = re.search(r"Test Case .-\[(\S+) \S+\]. (?:passed|failed|skipped) \((\d+\.\d+) seconds\)", line)
    if m:
        seconds[m.group(1)] += float(m.group(2))
for name, total in seconds.most_common():
    print(f"{total:.3f} {name}")
' > "$TIMINGS.new" && [ -s "$TIMINGS.new" ] && mv "$TIMINGS.new" "$TIMINGS"

if [ "$executed" -ne "$expected" ]; then
    echo "✕ ran $executed tests of $expected listed"
    failed=1
fi

if [ "$failed" -ne 0 ]; then
    grep -hE "error: -\[|: error: |Fatal error|exited with|signal" "${logs[@]}" | grep -v "CoreData" | head -40
    echo "✕ tests failed ($executed run, $(( $(date +%s) - started )) s; logs in $OUT)"
    exit 1
fi
echo "✓ $executed tests passed in $(( $(date +%s) - started )) s across $(( ${#logs[@]} )) processes"
