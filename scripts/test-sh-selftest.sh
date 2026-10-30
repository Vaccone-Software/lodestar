#!/bin/bash
# scripts/test.sh's own rules, checked without building or running a test:
# the results file, the quarantine, and the guarantees it already made
# (executed equals listed, a shard that runs nothing fails, an unlisted skip
# fails, a stopped shard is a hang, a failed run's shards replay).
#
# test.sh is run for real, in a scratch copy of the tree, with a fake `swift`
# and `xcrun xctest` first on PATH: the fake build succeeds, the fake list is
# scripts/test-sh-fixtures/tests.txt, and each fake shard prints the fixture
# log it was given and exits with the status it was given. The fixture logs
# are xctest's own lines (the failure, the skip and the interleaved output
# are from a real CI shard); died.log is a shard stopped inside a test.
#
#   scripts/test-sh-selftest.sh
#
# Exit status: 0 when every check holds. CI runs it before the build.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
fix="$here/test-sh-fixtures"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
broken=0

# Dates the quarantine rules are checked against, as the script sees them.
day() { python3 -c "import datetime,sys; print(datetime.date.today() + datetime.timedelta(days=int(sys.argv[1])))" "$1"; }

# A scratch tree to run test.sh in: its scripts, an allowlist that allows the
# one skip in failing.log, the shipped quarantine file's header (no entries),
# and the fake toolchain. `fresh <name>` leaves $root with a clean run: an app
# shard and the core shard, both passing, and a list of exactly their tests.
# Every case then changes one thing, so a run that fails fails for that.
fresh() {
    root="$work/$1"
    mkdir -p "$root/scripts" "$root/Tests" "$root/fake/bin/LodestarAppTests.xctest" "$root/fake/bin/LodestarCoreTests.xctest" \
        "$root/fake/xbin" "$root/fake/plan"
    cp "$here/test.sh" "$here/test-results.py" "$root/scripts/"
    cp "$here/../Tests/quarantine.txt" "$root/Tests/quarantine.txt"
    echo "any MainThreadWatchdogTests.testTheVerdictFollowsTheClockReadings" > "$root/Tests/allowed-skips.txt"
    cat > "$root/fake/xbin/swift" <<'SH'
#!/bin/bash
case "$1 $2" in
    "build --build-tests") exit 0;;
    "build --show-bin-path") echo "$FAKE/bin";;
    "test list") cat "$FAKE/tests.txt";;
esac
SH
    # The shard is told apart by the classes it was given, which the plan's
    # lists hold; it prints its fixture and exits as it was told. A shard
    # with a .hang file prints and then never moves again.
    cat > "$root/fake/xbin/xcrun" <<'SH'
#!/bin/bash
while [ $# -gt 0 ]; do [ "$1" = -XCTest ] && list=$2; shift; done
for l in .build/test-shards/*.list; do [ "$(cat "$l")" = "$list" ] && name=$(basename "$l" .list); done
cat "$FAKE/$name.log"
[ -f "$FAKE/$name.hang" ] && exec sleep 60
exit "$(cat "$FAKE/$name.exit" 2>/dev/null || echo 0)"
SH
    chmod +x "$root/fake/xbin/swift" "$root/fake/xbin/xcrun"
    shard app0 "LodestarAppTests.RetirementTests" clean-app.log
    shard core "LodestarCoreTests.AbandonmentTests" clean.log
    listing "AbandonmentTests|RetirementTests"
}

# The app shard becomes the one that fails: two failing tests and a skip.
failing_app() {
    shard app0 "LodestarAppTests.MainThreadWatchdogTests" failing.log "${1:-1}"
    listing "AbandonmentTests|MainThreadWatchdogTests"
}

# listing <regex>: the fake test list is the fixture's lines that match.
listing() { grep -E "$1" "$fix/tests.txt" > "$root/fake/tests.txt"; }

# shard <name> <classes> <fixture log> [exit status]
shard() {
    echo -n "$2" > "$root/fake/plan/$1.list"
    cp "$fix/$3" "$root/fake/$1.log"
    echo "${4:-0}" > "$root/fake/$1.exit"
}

quarantine() { echo "$1 $2 $3" >> "$root/Tests/quarantine.txt"; }

run() {
    (cd "$root" && PATH="$root/fake/xbin:$PATH" FAKE="$root/fake" TEST_SHARD_PLAN="${PLAN:-$root/fake/plan}" \
        TEST_SHARD_SECONDS="${SECONDS_LIMIT:-300}" CI= scripts/test.sh) > "$root/out.txt" 2>&1
    status=$?
}

# expect <what> <exit status wanted> [pattern in the output]...
expect() {
    local what=$1 want=$2 bad=""
    shift 2
    [ "$status" -eq "$want" ] || bad="exit status $status, wanted $want"
    for pattern in "$@"; do
        grep -qE -- "$pattern" "$root/out.txt" || bad="$bad; no '$pattern' in the output"
    done
    if [ -z "$bad" ]; then
        echo "  ok   $what"
    else
        echo "  FAIL $what: $bad"
        sed 's/^/       | /' "$root/out.txt" | tail -15
        broken=$((broken + 1))
    fi
}

echo "the results file"
fresh clean
run
expect "a clean run passes and says so" 0 "✓ 4 tests passed, 0 skipped"
python3 - "$root/.build/test-results/junit.xml" <<'PY' && echo "  ok   the clean run's junit.xml has a testcase per test, no failures" || { echo "  FAIL junit.xml of a clean run"; broken=$((broken + 1)); }
import sys, xml.etree.ElementTree as ET
r = ET.parse(sys.argv[1]).getroot()
cases = r.findall(".//testcase")
assert len(cases) == 4 and r.get("failures") == "0", (len(cases), r.attrib)
assert all(c.get("classname") and c.get("name") and c.get("time") for c in cases)
PY

fresh failing
failing_app
run
expect "a failure fails the run, with both its error lines read and its tests named" 1 "✕ tests failed" "MainThreadWatchdogTests.swift:41" \
    "failed: MainThreadWatchdogTests.testAResponsiveMainThreadIsLeftAlone"
python3 - "$root/.build/test-results/junit.xml" <<'PY' && echo "  ok   the junit.xml names the failures, the skip and every pass" || { echo "  FAIL junit.xml of a failing run"; broken=$((broken + 1)); }
import sys, xml.etree.ElementTree as ET
r = ET.parse(sys.argv[1]).getroot()
cases = {c.get("name"): c for c in r.findall(".//testcase")}
assert len(cases) == 7 and r.get("failures") == "2" and r.get("skipped") == "1", r.attrib
two = cases["testAResponsiveMainThreadIsLeftAlone"].findall("failure")
assert len(two) == 2 and "<b>nothing</b> & \"quotes\"" in two[1].text, two
assert two[0].get("type") == "XCTAssertEqual" and "MainThreadWatchdogTests.swift:37" in two[0].text
assert cases["testTheVerdictFollowsTheClockReadings"].find("skipped").get("message").startswith("LODESTAR_EDITOR_MEASURE")
assert cases["testALateAnswerIsReportedWithItsLength"].find("failure") is None
PY
mkdir -p "$work/replay" && cp -R "$root/." "$work/replay/" && rm -rf "$work/replay/.build/test-shards" "$work/replay/.build/test-results"
root="$work/replay"; PLAN=".build/test-shards-failed" run; unset PLAN
expect "a failed run's shards replay with TEST_SHARD_PLAN and fail the same way" 1 "replaying the shard plan" "✕ tests failed"

fresh unlisted
failing_app
echo -n > "$root/Tests/allowed-skips.txt"
run
expect "a skip the allowlist does not name fails the run" 1 "skipped without a place in Tests/allowed-skips.txt"

echo "the quarantine"
fresh quarantined
failing_app
quarantine MainThreadWatchdogTests.testAnOnTimeAnswerSaysNothing "$(day 14)" the clock moves on a runner
quarantine MainThreadWatchdogTests.testAResponsiveMainThreadIsLeftAlone "$(day 0)" expires today and still counts
run
expect "every failure quarantined: the run passes, the failures are at the foot of the summary" 0 \
    "✓ 4 tests passed, 1 skipped as allowed, 2 failed in quarantine" "⚠ 2 quarantined test\(s\) failed" "testAnOnTimeAnswerSaysNothing"
grep -q 'name="quarantined"' "$root/.build/test-results/junit.xml" && grep -c '<failure' "$root/.build/test-results/junit.xml" | grep -q 3 \
    && echo "  ok   the results file keeps the failures and marks them quarantined" \
    || { echo "  FAIL the results file of a quarantined run"; broken=$((broken + 1)); }

fresh half
failing_app
quarantine MainThreadWatchdogTests.testAnOnTimeAnswerSaysNothing "$(day 3)" only one of the two
run
expect "a failure that is not quarantined still fails the run, the quarantined one still shown" 1 "⚠ 1 quarantined" "✕ tests failed"

fresh expired
quarantine RetirementTests.testAnEmptyWindowHasNoSurfaces "$(day -1)" expired yesterday
run
expect "an expired entry fails the run before any test runs" 1 "expired on" "quarantine.txt breaks its own rules"
grep -q "Executed\|replaying" "$root/out.txt" && { echo "  FAIL the expired run went on to run tests"; broken=$((broken + 1)); }

fresh far
quarantine RetirementTests.testAnEmptyWindowHasNoSurfaces "$(day 15)" parked for more than a fortnight
run
expect "an entry more than 14 days out fails the run" 1 "more than 14 days"

fresh unknown
quarantine RetirementTests.testARenamedTest "$(day 3)" the test was renamed
run
expect "an entry naming a test that is not in the list fails the run" 1 "not in the test list"

fresh malformed
echo "RetirementTests.testAnEmptyWindowHasNoSurfaces soon" >> "$root/Tests/quarantine.txt"
run
expect "an entry with no date and no reason fails the run" 1 "want '<Class>.<test> <expires"

fresh crash
shard app0 "LodestarAppTests.SlabTests" died.log 1
listing "SlabTests|AbandonmentTests"
quarantine SlabTests.testKeepsChosenCardFollowsTheSelection "$(day 3)" quarantine does not excuse a crash
run
expect "a quarantined test that kills its process still fails the run" 1 "ended before its last test" \
    "failed: SlabTests.testKeepsChosenCardFollowsTheSelection started and never finished"

echo "what test.sh already guaranteed"
fresh exits
echo 1 > "$root/fake/core.exit"
run
expect "a shard that exits non-zero with no failure in its log fails the run" 1 "✕ tests failed"

fresh empty
printf "Test Suite 'Selected tests' passed at 2026-10-26 00:35:10.340.\n\t Executed 0 tests, with 0 failures (0 unexpected) in 0.000 (0.001) seconds\n" > "$root/fake/core.log"
run
expect "a shard that runs no tests fails the run" 1 "core ran no tests"

fresh short
echo "LodestarCoreTests.AbandonmentTests/testNeverRan" >> "$root/fake/tests.txt"
run
expect "a total that is not the test list fails the run" 1 "ran 4 tests of 5 listed"

fresh hang
touch "$root/fake/app0.hang"
SECONDS_LIMIT=2 run
expect "a shard whose log stops moving is a hang, and is stopped" 1 "app0 has not moved in 2s"

echo "the shipped quarantine file"
if python3 "$here/test-results.py" quarantine "$here/../Tests/quarantine.txt" "$fix/tests.txt" --today "$(day 0)" > "$work/shipped.txt" 2>&1; then
    echo "  ok   Tests/quarantine.txt passes its own rules"
else
    echo "  FAIL Tests/quarantine.txt: $(cat "$work/shipped.txt")"
    broken=$((broken + 1))
fi

if [ "$broken" -ne 0 ]; then
    echo "✕ $broken check(s) of scripts/test.sh failed"
    exit 1
fi
echo "✓ scripts/test.sh keeps its rules"
