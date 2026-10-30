#!/bin/bash
# The whole suite, sharded: every test class runs, spread across a few
# xctest processes at once. Half a serial `swift test` is waiting — run
# loops, timers, WindowServer — so overlapping it pays: about 50 s becomes
# about 12 s on an M1 Max, with the same CPU.
#
#   scripts/test.sh              six app shards plus the core bundle
#   TEST_SHARDS=8 scripts/test.sh
#   TEST_LIGHT=1 scripts/test.sh the suite as a Mac in Light runs it, without
#                                touching the Mac's setting: the processes are
#                                started with NSRequiresAquaSystemAppearance, so
#                                only they are Aqua (a runner is not a desk in Dark)
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
# a shard whose log has not moved in TEST_SHARD_SECONDS (300; its stack is
# sampled to .build/test-shards/<shard>.hang.txt), and a skip that
# Tests/allowed-skips.txt does not allow.
#
# Every run, passes too, leaves .build/test-results/junit.xml: one testcase
# per test with its seconds, and a failure or skip with its message, read
# from the shards' logs by scripts/test-results.py. CI uploads it, and
# scripts/flake-history.sh counts failures per test over the runs.
#
# A test in Tests/quarantine.txt still runs, but its failure does not fail
# the run: it is printed at the foot of the summary and marked in the
# results file. The file fails the run instead when an entry has expired,
# is parked for more than 14 days, or names a test that is not in the list.
# A quarantined test that hangs or kills its process is not excused: only
# a failure the log records is. scripts/test-sh-selftest.sh checks these
# rules against fixture logs, with nothing built.
set -uo pipefail
cd "$(dirname "$0")/.."

SHARDS=${TEST_SHARDS:-6}
SHARD_SECONDS=${TEST_SHARD_SECONDS:-300}
OUT=.build/test-shards
RESULTS=.build/test-results
TIMINGS=.build/test-timings.txt
started=$(date +%s)
# The last run's results are gone before anything else can fail: a build
# restored from a cache, or a run that stops early, must not leave an old
# file to be taken for this one's.
rm -rf "$RESULTS"

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
if ! python3 scripts/test-results.py quarantine Tests/quarantine.txt "$OUT/tests.txt" --today "$(date +%Y-%m-%d)"; then
    echo "✕ Tests/quarantine.txt breaks its own rules (see its header)"
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

# Light, for these processes alone (an argument-domain default; the Mac's own
# setting is not read or written).
xctest_args=()
[ -n "${TEST_LIGHT:-}" ] && xctest_args=(-NSRequiresAquaSystemAppearance YES)

pids=()
logs=()
for list in "$OUT"/app*.list "$OUT/core.list"; do
    name=$(basename "$list" .list)
    bundle="$APP_BUNDLE"
    [ "$name" = core ] && bundle="$CORE_BUNDLE"
    xcrun xctest ${xctest_args[@]+"${xctest_args[@]}"} -XCTest "$(cat "$list")" "$bundle" > "$OUT/$name.log" 2>&1 &
    pids+=($!)
    logs+=("$OUT/$name.log")
done

# A shard that hangs (a deadlock, a wait that never ends) would hold the
# run, and a ship, for ever. A hang is a shard that has stopped moving,
# not one that is slow: every test writes a line as it starts and ends,
# so a log untouched for the limit is a shard stuck inside one test. The
# limit was once on the whole shard, and a slow runner stopped five shards
# that were still passing tests (2026-10-25, the longest a single class
# taking six minutes there), which read as a red main and held a ship.
# Past the limit the shard's stack is sampled, so the hang can be read,
# and the shard is stopped; the others run on.
failed=0
while :; do
    alive=()
    for index in "${!pids[@]}"; do
        kill -0 "${pids[$index]}" 2>/dev/null && alive+=("$index")
    done
    [ ${#alive[@]} -eq 0 ] && break
    now=$(date +%s)
    for index in "${alive[@]}"; do
        log=${logs[$index]}
        moved=$(stat -f %m "$log" 2>/dev/null || echo "$now")
        [ $((now - moved)) -lt "$SHARD_SECONDS" ] && continue
        pid=${pids[$index]}
        name=$(basename "$log" .log)
        in=$(grep -E "^Test Case .* started" "$log" | tail -1)
        echo "✕ $name has not moved in ${SHARD_SECONDS}s, in: $in"
        sample "$pid" 2 -file "$OUT/$name.hang.txt" >/dev/null 2>&1 \
            && echo "  its stack: $OUT/$name.hang.txt"
        kill -TERM "$pid" 2>/dev/null
        sleep 2
        kill -KILL "$pid" 2>/dev/null
        failed=1
    done
    sleep 0.5
done
# Each process's exit status is kept, not counted yet: a shard whose only
# failures are quarantined exits non-zero too, and the log says which.
statuses=()
for index in "${!pids[@]}"; do
    wait "${pids[$index]}" 2>/dev/null
    statuses[$index]=$?
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

# The results file, and what the logs say of each test. A shard that
# exited non-zero must have a failure to show for it: the quarantined ones
# are excused, a non-zero exit with no failure in its log is not.
mkdir -p "$RESULTS"
quarantined=""
if results=$(python3 scripts/test-results.py junit --out "$RESULTS/junit.xml" --quarantine Tests/quarantine.txt "${logs[@]}"); then
    grep -E "^PROBLEM " <<<"$results" | sed 's/^PROBLEM /✕ /'
    grep -qE "^PROBLEM " <<<"$results" && failed=1
    quarantined=$(grep -E "^QUARANTINED " <<<"$results" | sed -E 's/^QUARANTINED //')
    for index in "${!logs[@]}"; do
        line=$(grep -F "LOG ${logs[$index]} " <<<"$results")
        bad=$(sed -En 's/.* failed=([0-9]+) .*/\1/p' <<<"$line")
        excused=$(sed -En 's/.* quarantined=([0-9]+)$/\1/p' <<<"$line")
        if [ "${bad:-1}" -ne 0 ] || { [ "${statuses[$index]}" -ne 0 ] && [ "${excused:-0}" -eq 0 ]; }; then
            failed=1
        fi
    done
else
    echo "✕ the results file could not be written"
    failed=1
fi

# What a quarantine is costing, last in the output where it is read.
quarantine_note() {
    [ -n "$quarantined" ] || return 0
    echo ""
    echo "⚠ $(wc -l <<<"$quarantined" | tr -d ' ') quarantined test(s) failed. They do not fail the run, and each has a deadline in Tests/quarantine.txt:"
    sed 's/^/    /' <<<"$quarantined"
}

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
    # By name, one line each: the error lines above are in the order the
    # shards wrote them, and a test that never finished has none.
    grep -E "^FAIL " <<<"${results:-}" | cut -c1-220 | sed 's/^FAIL /  failed: /'
    quarantine_note
    echo "✕ tests failed ($executed run, $(( $(date +%s) - started )) s; logs in $OUT, results in $RESULTS)"
    echo "  the same shards again: TEST_SHARD_PLAN=.build/test-shards-failed scripts/test.sh"
    exit 1
fi
failing=0
[ -n "$quarantined" ] && failing=$(wc -l <<<"$quarantined" | tr -d ' ')
note=""
[ "$failing" -gt 0 ] && note=", $failing failed in quarantine"
echo "✓ $((executed - skipped - failing)) tests passed, $skipped skipped as allowed$note, in $(( $(date +%s) - started )) s across $(( ${#logs[@]} )) processes"
quarantine_note
