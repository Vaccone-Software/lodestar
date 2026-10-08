#!/bin/bash
# The whole suite, sharded: every test class runs, spread across a few
# xctest processes at once. Half a serial `swift test` is waiting — run
# loops, timers, WindowServer — so overlapping it pays: about 50 s becomes
# about 12 s on an M1 Max, with the same CPU.
#
#   scripts/test.sh              six app shards plus the core bundle
#   TEST_SHARDS=8 scripts/test.sh
#   TEST_SHARD_PLAN=.build/test-shards-failed scripts/test.sh
#                                the same classes in the same processes as
#                                the run that failed: which tests share a
#                                process changes run to run, so a failure
#                                that depends on order is replayed exactly
#
# Not `swift test --parallel`: that spawns one process per test, each
# reloading AppKit, and measured slower than serial. Not concurrent
# `swift test --filter` either: they would fight over the .build lock.
#
# Classes are balanced by the time each took last run (.build/test-timings.txt,
# rewritten after every run; a class with no timing yet goes to the lightest
# shard). A shard that runs no tests fails the run: a bad -XCTest name runs
# nothing and exits 0. So does a total that does not match the test list,
# a shard still running after TEST_SHARD_SECONDS (300; its stack is sampled
# to .build/test-shards/<shard>.hang.txt), and a skip that
# Tests/allowed-skips.txt does not allow.
set -uo pipefail
cd "$(dirname "$0")/.."

SHARDS=${TEST_SHARDS:-6}
SHARD_SECONDS=${TEST_SHARD_SECONDS:-300}
OUT=.build/test-shards
TIMINGS=.build/test-timings.txt
started=$(date +%s)

build_tests() { build=$(swift build --build-tests 2>&1); }
built=1
if ! build_tests; then
    built=0
    # macOS remounts the Metal toolchain (MLX's kernels) under a new path
    # now and then, and the cached build plan keeps the old one. The plan
    # is a cache: dropped, it is made again.
    if grep -q "MetalToolchain.*No such file" <<<"$build"; then
        echo "→ the Metal toolchain moved; rebuilding the build plan"
        rm -rf .build/out/Intermediates.noindex/XCBuildData
        build_tests && built=1
    fi
fi
if [ "$built" -ne 1 ]; then
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
if [ -n "${TEST_SHARD_PLAN:-}" ]; then
    cp "$TEST_SHARD_PLAN"/*.list "$OUT"/ || { echo "✕ no shard plan in $TEST_SHARD_PLAN"; exit 1; }
    echo "→ replaying the shard plan in $TEST_SHARD_PLAN"
else
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
fi

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

# A shard that hangs (a deadlock, a wait that never ends) would hold the
# run, and a ship, for ever. Past the limit its stack is sampled, so the
# hang can be read, and it is stopped.
failed=0
deadline=$((SECONDS + SHARD_SECONDS))
while :; do
    alive=()
    for index in "${!pids[@]}"; do
        kill -0 "${pids[$index]}" 2>/dev/null && alive+=("$index")
    done
    [ ${#alive[@]} -eq 0 ] && break
    if [ "$SECONDS" -ge "$deadline" ]; then
        for index in "${alive[@]}"; do
            pid=${pids[$index]}
            name=$(basename "${logs[$index]}" .log)
            in=$(grep -E "^Test Case .* started" "${logs[$index]}" | tail -1)
            echo "✕ $name still running after ${SHARD_SECONDS}s, in: $in"
            sample "$pid" 2 -file "$OUT/$name.hang.txt" >/dev/null 2>&1 \
                && echo "  its stack: $OUT/$name.hang.txt"
            kill -TERM "$pid" 2>/dev/null
        done
        sleep 2
        for index in "${alive[@]}"; do kill -KILL "${pids[$index]}" 2>/dev/null; done
        failed=1
        break
    fi
    sleep 0.5
done
for index in "${!pids[@]}"; do
    wait "${pids[$index]}" 2>/dev/null || failed=1
done

# A process that died mid-run (a crash, an abort, an exit) leaves the
# summary of the last class it finished and no word of what killed it, so
# its tests are silently missing from the total. Its log names the test it
# was in: the last one started and never finished.
for log in "${logs[@]}"; do
    if ! grep -qE "Test Suite '(Selected tests|All tests)' (passed|failed)" "$log"; then
        died=$(grep -E "^Test Case .* (started|passed|failed|skipped)" "$log" | tail -1)
        echo "✕ $(basename "$log" .log) ended before its last test: $died"
        tail -12 "$log" | cut -c1-240
        failed=1
    fi
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

# Next run's balance: seconds per class, summed from every test line. Only
# a whole run is a measure: a stopped one would leave most classes untimed
# and pile them onto one shard next time.
[ "$executed" -eq "$expected" ] && cat "${logs[@]}" | python3 -c '
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

# Skips are in "Executed N"; each must be one the allowlist expects here.
where=desk
[ -n "${CI:-}" ] && where=ci
grep -hE "^Test Case '-\[\S+ \S+\]' skipped" "${logs[@]}" \
    | sed -E "s/^Test Case '-\[[A-Za-z0-9_]+\.([A-Za-z0-9_]+) ([A-Za-z0-9_]+)\]'.*/\1.\2/" | sort -u > "$OUT/skipped.txt"
skipped=$(wc -l < "$OUT/skipped.txt" | tr -d ' ')
unexpected=$(python3 - "$OUT/skipped.txt" Tests/allowed-skips.txt "$where" <<'PY'
import sys, fnmatch
skipped, allowed, where = sys.argv[1], sys.argv[2], sys.argv[3]
rules = []
for line in open(allowed):
    line = line.split("#")[0].split()
    if len(line) == 2 and line[0] in ("any", where):
        rules.append(line[1])
for name in (l.strip() for l in open(skipped)):
    if name and not any(fnmatch.fnmatchcase(name, r) for r in rules):
        print(name)
PY
)
if [ -n "$unexpected" ]; then
    echo "✕ skipped without a place in Tests/allowed-skips.txt (at the $where):"
    echo "$unexpected" | sed 's/^/    /'
    grep -hE -A1 "^Test Case .* skipped|: Test skipped" "${logs[@]}" | grep -F "$(echo "$unexpected" | head -3 | sed -E 's/.*\.//')" | head -6 | cut -c1-200
    failed=1
fi

if [ "$failed" -ne 0 ]; then
    grep -hE "error: -\[|: error: |Fatal error|exited with|signal" "${logs[@]}" | grep -v "CoreData" | head -40
    rm -rf .build/test-shards-failed && cp -R "$OUT" .build/test-shards-failed
    echo "✕ tests failed ($executed run, $(( $(date +%s) - started )) s; logs in $OUT)"
    echo "  the same shards again: TEST_SHARD_PLAN=.build/test-shards-failed scripts/test.sh"
    exit 1
fi
echo "✓ $((executed - skipped)) tests passed, $skipped skipped as allowed, in $(( $(date +%s) - started )) s across $(( ${#logs[@]} )) processes"
