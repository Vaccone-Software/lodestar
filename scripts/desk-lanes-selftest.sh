#!/bin/bash
# scripts/desk-lanes.py's own rules, checked on fixtures without building or
# running a test: the races a Thread Sanitizer log holds (deduplicated by top
# frame), the tests read out of an xctest log, the allowlist's timing lane and
# live rules, and the guard that says a test has failed run after run.
#
#   scripts/desk-lanes-selftest.sh
#
# Exit status: 0 when every check holds. CI runs it beside test.sh's.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
broken=0
helper() { python3 "$here/desk-lanes.py" "$@"; }

# check <what> <expected substring or "-" for none> <actual>
has() {
    if grep -qF -- "$2" <<<"$3"; then echo "  ok   $1"; else echo "  FAIL $1: wanted \"$2\" in:"; sed 's/^/         /' <<<"$3"; broken=$((broken + 1)); fi
}
lacks() {
    if grep -qF -- "$2" <<<"$3"; then echo "  FAIL $1: found \"$2\" in:"; sed 's/^/         /' <<<"$3"; broken=$((broken + 1)); else echo "  ok   $1"; fi
}

echo "races"
mkdir -p "$work/tree/Sources/Core" "$work/tree/Tests/CoreTests"
touch "$work/tree/Sources/Core/Watchdog.swift" "$work/tree/Tests/CoreTests/WatchdogTests.swift"
cat > "$work/tsan.log" <<'LOG'
Test Case '-[CoreTests.WatchdogTests testOne]' started.
==================
WARNING: ThreadSanitizer: data race (pid=101)
  Write of size 1 at 0x0001 by main thread:
    #0 Watchdog.stop() Watchdog.swift:131 (CoreTests:arm64+0x1)
    #1 WatchdogTests.testOne() WatchdogTests.swift:275 (CoreTests:arm64+0x2)

  Previous read of size 1 at 0x0001 by thread T27:
    #0 Watchdog.loop() Watchdog.swift:175 (CoreTests:arm64+0x3)
    #1 __NSThread__start__ <null> (Foundation:arm64e+0x53c94)

SUMMARY: ThreadSanitizer: data race Watchdog.swift:131 in Watchdog.stop()
==================
Test Case '-[CoreTests.WatchdogTests testOne]' passed (1.9 seconds).
==================
WARNING: ThreadSanitizer: data race (pid=101)
  Write of size 1 at 0x0001 by main thread:
    #0 Watchdog.stop() Watchdog.swift:131 (CoreTests:arm64+0x1)
  Previous read of size 1 at 0x0001 by thread T9:
    #0 Watchdog.loop() Watchdog.swift:175 (CoreTests:arm64+0x3)

SUMMARY: ThreadSanitizer: data race Watchdog.swift:131 in Watchdog.stop()
==================
WARNING: ThreadSanitizer: Swift access race (pid=101)
  Modifying access of Swift variable at 0x0002 by thread T2:
    #0 Cache.put(_:) Cache.swift:9 (CoreTests:arm64+0x4)

SUMMARY: ThreadSanitizer: Swift access race Cache.swift:9 in Cache.put(_:)
==================
LOG
out=$(helper races --root "$work/tree" --results "$work/results.tsv" "$work/tsan.log")
has "three reports, two distinct" "RACES 2 3" "$out"
has "the same top frame counts twice" "RACE 2 data race Watchdog.swift:131 in Watchdog.stop()" "$out"
has "the first frame in the repository is found" "Sources/Core/Watchdog.swift:131 Watchdog.stop()" "$out"
has "a race becomes a failed row for the guard" "tsan race: data race Watchdog.swift:131 in Watchdog.stop()	fail	" "$(cat "$work/results.tsv")"
out=$(helper races --root "$work/tree" /dev/null)
has "a log with no race says none" "RACES 0 0" "$out"

echo "tests"
out=$(helper tests "$here/test-sh-fixtures/failing.log")
has "a failure is a fail with its message" "MainThreadWatchdogTests.testAnOnTimeAnswerSaysNothing	fail	" "$out"
has "a skip is not run, with its reason" "not run	LODESTAR_EDITOR_MEASUR" "$out"
out=$(helper tests "$here/test-sh-fixtures/died.log")
has "a test that never finished is a fail" "started and never finished" "$out"

echo "the allowlist"
cat > "$work/allowed.txt" <<'LIST'
# Live tests
any LiveTests.*
any OtherLiveTests.testOne   # with a note
ci OCRTests.testReads
# The timing lane: real time.
ci WatchdogTests.testReal
ci SearchTests.testFast
desk ReplayTests.testAUC
LIST
has "the timing lane is the ci rules after its comment" "WatchdogTests.testReal" "$(helper timing "$work/allowed.txt")"
lacks "and not the ci rules before it" "OCRTests" "$(helper timing "$work/allowed.txt")"
has "the live rules are the any rules" "OtherLiveTests.testOne" "$(helper any "$work/allowed.txt")"
lacks "and not the desk's" "ReplayTests" "$(helper any "$work/allowed.txt")"
printf 'static let standard = EditorManifest(\n        repo: "org/model-4bit", revision: "abc123def",\n' > "$work/pin.swift"
has "a pinned model's repo and revision" "org/model-4bit abc123def" "$(helper pin "$work/pin.swift" standard)"
helper pin "$work/pin.swift" full > /dev/null 2>&1
if [ $? -ne 0 ]; then echo "  ok   an unknown manifest is an error"; else echo "  FAIL an unknown manifest passed"; broken=$((broken + 1)); fi

echo "the guard"
# report <date> <lane> <status> <rows...>: one dated run, rows as name:verdict
report() {
    local day=$1 lane=$2 state=$3
    shift 3
    mkdir -p "$work/reports/$day"
    printf '%s\t5\tnote\n' "$state" > "$work/reports/$day/$lane.status"
    : > "$work/reports/$day/$lane.results.tsv"
    for row in "$@"; do printf '%s\t%s\t\n' "${row%%:*}" "${row#*:}" >> "$work/reports/$day/$lane.results.tsv"; done
}
rm -rf "$work/reports"
report 2026-10-04 live failed "Mic.test:fail" "Other.test:pass"
report 2026-10-11 live failed "Mic.test:fail" "Other.test:fail"
report 2026-10-18 live failed "Mic.test:not run" "Other.test:fail"
report 2026-10-25 live failed "Mic.test:fail" "Other.test:pass" "Fresh.test:fail"
out=$(helper summary "$work/reports" 2026-10-25); status=$?
has "failing in the run before and the one before that: since the first" "failing since 2026-10-04: live: Mic.test: fix or delete" "$out"
lacks "a first failure is not yet news" "Fresh.test: fix" "$out"
if [ "$status" -eq 1 ]; then echo "  ok   a lane that failed makes the summary exit 1"; else echo "  FAIL exit $status"; broken=$((broken + 1)); fi
out=$(helper summary "$work/reports" 2026-10-18)
has "a pass ends the chain (10-04 passed, so 10-11 is the start)" "failing since 2026-10-11: live: Other.test: fix or delete" "$out"
has "a not run in between is passed over" "failing since 2026-10-04: live: Mic.test" "$(helper summary "$work/reports" 2026-10-25)"
lacks "and is not itself a failure" "live: Mic.test" "$out"
has "a lane never run today says so" "tsan      not run today" "$out"
report 2026-11-01 tsan ok "A.test:pass"
out=$(helper summary "$work/reports" 2026-11-01); status=$?
if [ "$status" -eq 0 ]; then echo "  ok   a lane that passed makes the summary exit 0"; else echo "  FAIL exit $status"; broken=$((broken + 1)); fi

if [ "$broken" -ne 0 ]; then
    echo "✕ $broken check(s) of scripts/desk-lanes.py failed"
    exit 1
fi
echo "✓ scripts/desk-lanes.py keeps its rules"
