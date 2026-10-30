#!/bin/bash
# The weekly desk lanes: what scripts/test.sh and CI cannot run, run once a
# week on the desk while it is idle, each with a dated report. Three lanes:
#
#   tsan      the Core suite, and the App classes that touch threads, under
#             Thread Sanitizer (a separate build in .build-tsan). A test that
#             passes can still be a race; TSan reports it. The races are
#             listed, deduplicated by their top frame.
#   coverage  the whole suite once with coverage on (.build-cov), and a report:
#             every file's lines, then the areas the review names (taps, the
#             updater, sealed storage, deletion paths, migrations) with their
#             uncovered lines and the functions never called. A report, not a
#             gate: nothing here fails for a number.
#   live      every test Tests/allowed-skips.txt lets skip everywhere (`any`),
#             with the environment each one decides on, then the timing lane
#             (the `ci` tests that are about real time, run on a quiet desk),
#             then the dictation evaluation. A test that cannot run says why
#             ("not run: <why>") instead of passing by skipping.
#
#   scripts/desk-lanes.sh all                 the three, in that order
#   scripts/desk-lanes.sh tsan                one lane (any number may be named)
#   scripts/desk-lanes.sh summary             only the summary of today's folder
#   DESK_LANES_TSAN_APP=all scripts/desk-lanes.sh tsan
#                                             the whole App bundle under TSan, not
#                                             the classes below (not tried: see
#                                             "What TSan can run")
#   DESK_LANES_COVERAGE_FILTER=LodestarCoreTests scripts/desk-lanes.sh coverage
#                                             coverage of a part, to try the lane
#                                             (the whole suite takes about 40 min
#                                             under coverage; the report says it
#                                             is a part)
#   DESK_LANES_DOWNLOAD=1 scripts/desk-lanes.sh live
#                                             also the 3.6 GB model download test
#   FORCE=1                                   run the focus-taking live tests
#                                             without waiting for an idle keyboard
#
# Exit status: 0 when every lane that ran passed; 1 when one failed (a race, a
# failing test, a build that broke, a lane whose own recipe went stale).
#
# What it takes. It takes the screen (the suite puts windows up, the
# conformance and window tests drive TextEdit, Brave and real windows), it
# plays and listens, and it holds several cores for about half an hour. Run it
# when the desk is idle, never in working hours; the live tests that move
# focus run only when the keyboard has been idle for 5 s, and say so when it
# was not. The Mac must be awake, logged in and unlocked.
#
# Where the reports go. ~/Library/Logs/Lodestar/desk-lanes/<date>/, not
# anything under ~/.local/share/lodestar (that is Lodestar's sealed data, which
# nothing here reads: the tests run in a home of their own). Per lane:
#   summary.txt            the one-screen summary, with the guard (below)
#   <lane>.txt             the lane's report (races, coverage tables, live table)
#   <lane>.status          ok | failed | not run, seconds, a note
#   <lane>.results.tsv     one row per test or race: name, pass|fail|not run, note
#   logs/                  raw build and test logs; coverage never leaves the
#                          profile data in .build-cov
# Scratch (the dictation evaluation's synthesized audio, 50 MB) is in
# ~/Library/Caches/Lodestar/desk-lanes, and is made afresh each run.
#
# The guard. A name that fails in a lane's results and failed in the same
# lane's previous run, and the one before, back to the first, is said in the
# summary to be "failing since <date>: fix or delete". A run where it passed
# ends the chain; a run where it was not run (no microphone, no Accessibility)
# is passed over. This is the whole policy: a live test that fails for two
# weeks gets fixed or deleted. Nothing retries, nothing is skipped to get a
# green lane.
#
# What TSan can run. Core: all of it, and it is quick (3 min). App: the build
# works and the tests run under it (it found MainThreadWatchdog's race on the
# first try), but only a list of thread-touching classes was tried (a hundred
# tests, under a minute): the watchdog, the health monitor's lock and stress tests, the taps'
# recovery, the sealed clipboard store, the feedback outbox, the model and
# speech and update deadlines. The rest of the App bundle is windows,
# AppKit and MLX; whether all of it survives the sanitizer was not tried, so
# it is behind DESK_LANES_TSAN_APP=all and not on by default. The timing lane's
# tests run too (the race in MainThreadWatchdog is in one), but a real-time
# bound cannot hold under a sanitizer's slowdown (the clipboard search took
# 8.5 s against its 6 s), so a timing test that fails is set aside as "not
# run", never counted as a failure; a race in it still is.
#
# Schedule it. Nothing installs this: the repository holds a template, and the
# schedule is yours to approve. The template is
# scripts/com.vaccone.lodestar.desk-lanes.plist (Sundays at 03:00):
#
#   cp scripts/com.vaccone.lodestar.desk-lanes.plist ~/Library/LaunchAgents/
#   (edit the two paths in it, then)
#   launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.vaccone.lodestar.desk-lanes.plist
#
# Remove it:
#
#   launchctl bootout gui/$(id -u)/com.vaccone.lodestar.desk-lanes
#   rm ~/Library/LaunchAgents/com.vaccone.lodestar.desk-lanes.plist
#
# A launchd job has no Accessibility, Microphone or Screen Recording grant of
# its own (the grant belongs to the program that asks, here /bin/bash and
# xctest), so under launchd the live tests that need Accessibility say "not
# run: not trusted for accessibility". To give them the grant, start the script
# from an app that has it: the plist's comment shows how (Terminal opens it).
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD
HELPER=("python3" "$ROOT/scripts/desk-lanes.py")
ALLOW=Tests/allowed-skips.txt
TAB=$'\t'

DATE=${DESK_LANES_DATE:-$(date +%Y-%m-%d)}
REPORTS=${DESK_LANES_REPORTS:-$HOME/Library/Logs/Lodestar/desk-lanes}
SCRATCH=${DESK_LANES_SCRATCH:-$HOME/Library/Caches/Lodestar/desk-lanes}
DIR=$REPORTS/$DATE

# A TSan test run that has not written a line in this long is stuck (a
# deadlock, a wait that never ends): its stack is sampled and it is stopped,
# as test.sh does. The live tests are given longer: a model load and a
# minute of measuring are silent.
TSAN_STALL=${DESK_LANES_TSAN_STALL:-900}
COVERAGE_STALL=${DESK_LANES_COVERAGE_STALL:-600}
LIVE_STALL=${DESK_LANES_LIVE_STALL:-1800}

# The App classes that touch threads, run under TSan (see the header).
TSAN_APP_CLASSES=(
    HealthMonitorLockTests HealthMonitorStressTests MainThreadWatchdogTests EditorStallTests
    ClipboardStoreSealedTests FeedbackOutboxTests EditorModelDeadlineTests
    SpeechDeadlineTests UpdateToolDeadlineTests UpdateWatchdogTests
    MouseScrollTapTests TapRecoveryScenarioTests LodeTapScenarioTests
)

lanes=()
for arg in "$@"; do
    case "$arg" in
        all) lanes+=(tsan coverage live) ;;
        tsan|coverage|live|summary) lanes+=("$arg") ;;
        *) echo "usage: scripts/desk-lanes.sh all | tsan | coverage | live | summary"; exit 64 ;;
    esac
done
[ ${#lanes[@]} -eq 0 ] && { echo "usage: scripts/desk-lanes.sh all | tsan | coverage | live | summary"; exit 64; }

mkdir -p "$DIR/logs" "$SCRATCH"

# One run at a time: the night job and a hand-started run would fight over
# the same build folders and the same windows.
LOCK=$SCRATCH/running.lock
if [ "${lanes[0]}" != summary ]; then
    if ! mkdir "$LOCK" 2>/dev/null; then
        holder=$(cat "$LOCK/pid" 2>/dev/null)
        if [ -n "$holder" ] && kill -0 "$holder" 2>/dev/null; then
            echo "✕ desk-lanes is already running (pid $holder)"
            exit 75
        fi
        rm -rf "$LOCK"; mkdir "$LOCK"
    fi
    echo $$ > "$LOCK/pid"
    trap 'rm -rf "$LOCK"' EXIT
fi

# ---------------------------------------------------------------- helpers ----
# run_watched LOG STALL COMMAND...: the command's output goes to LOG. A log
# untouched for STALL seconds is a command stuck inside something: its stack is
# sampled to LOG.hang.txt, and it is stopped (status 124).
run_watched() {
    local log=$1 stall=$2
    shift 2
    "$@" > "$log" 2>&1 < /dev/null &
    local pid=$! now moved
    while kill -0 "$pid" 2>/dev/null; do
        now=$(date +%s)
        moved=$(stat -f %m "$log" 2>/dev/null || echo "$now")
        if [ $((now - moved)) -ge "$stall" ]; then
            sample "$pid" 2 -file "$log.hang.txt" >/dev/null 2>&1
            pkill -TERM -P "$pid" 2>/dev/null
            kill -TERM "$pid" 2>/dev/null
            sleep 2
            pkill -KILL -P "$pid" 2>/dev/null
            kill -KILL "$pid" 2>/dev/null
            wait "$pid" 2>/dev/null
            return 124
        fi
        sleep 1
    done
    wait "$pid"
}

# The lane's files for today are made afresh; a lane run twice in a day keeps
# only its last.
begin_lane() {
    lane=$1
    lane_started=$(date +%s)
    rm -f "$DIR/$lane.txt" "$DIR/$lane.status" "$DIR/$lane.results.tsv"
    : > "$DIR/$lane.results.tsv"
    echo "→ $lane"
}

# finish_lane STATE NOTE: ok | failed | not run, and the line that says why.
finish_lane() {
    printf '%s\t%s\t%s\n' "$1" "$(( $(date +%s) - lane_started ))" "$2" > "$DIR/$lane.status"
    echo "  $lane: $1: $2"
    if [ "$1" = failed ]; then return 1; fi
    return 0
}

# result NAME pass|fail|not run NOTE: one row of the lane's results.
result() {
    printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$DIR/$lane.results.tsv"
}

# The first error a build log has, for a one-line note.
first_error() {
    grep -E "error:" "$1" | grep -v "^warning" | head -1 | cut -c1-200
}

# Seconds since the keyboard or mouse was last touched.
idle_seconds() {
    ioreg -c IOHIDSystem | awk '/HIDIdleTime/ {print int($NF/1000000000); exit}'
}

# The test bundles of a build whose bin path is $1. Xcode 27's SwiftPM has one
# per test target; an older one has a single package bundle (test.sh's rule).
find_bundles() {
    APP_BUNDLE="$1/LodestarAppTests.xctest"
    CORE_BUNDLE="$1/LodestarCoreTests.xctest"
    if [ ! -d "$APP_BUNDLE" ]; then
        APP_BUNDLE=$(ls -d "$1"/*PackageTests.xctest 2>/dev/null | head -1)
        CORE_BUNDLE=$APP_BUNDLE
    fi
    [ -d "$APP_BUNDLE" ] && [ -d "$CORE_BUNDLE" ]
}

# ------------------------------------------------------------------- tsan ----
lane_tsan() {
    begin_lane tsan
    local scratch=.build-tsan log
    log=$DIR/logs/tsan-build.log
    if ! swift build --build-tests --sanitize=thread --scratch-path "$scratch" > "$log" 2>&1; then
        finish_lane failed "the tests do not build with the sanitizer: $(first_error "$log")"
        return
    fi
    local bin
    bin=$(swift build --build-tests --sanitize=thread --scratch-path "$scratch" --show-bin-path 2>/dev/null)
    if ! find_bundles "$bin"; then
        finish_lane failed "no test bundles in $bin"
        return
    fi
    # A clean result is only worth something if the sanitizer is in the
    # process: the bundle must link its runtime.
    if ! otool -L "$CORE_BUNDLE/Contents/MacOS/"* 2>/dev/null | grep -q "libclang_rt.tsan"; then
        finish_lane failed "the Core bundle does not link the thread sanitizer, so a result means nothing"
        return
    fi

    # The timing lane's tests are about real time, which TSan's slowdown breaks
    # (the clipboard search took 8.5 s against its 6 s). They still run, because
    # the real thread in them is what a race needs: a race in one is reported
    # like any other, and only the failed bound is set aside (below).
    local filters=() rule class
    filters+=(--filter 'LodestarCoreTests\.')
    local app_note="App: ${#TSAN_APP_CLASSES[@]} thread-touching classes"
    if [ "${DESK_LANES_TSAN_APP:-}" = all ]; then
        filters+=(--filter 'LodestarAppTests\.')
        app_note="App: the whole bundle"
    else
        local joined
        joined=$(IFS='|'; echo "${TSAN_APP_CLASSES[*]}")
        filters+=(--filter "LodestarAppTests\\.($joined)/")
    fi

    local tests_log=$DIR/logs/tsan-tests.log status
    run_watched "$tests_log" "$TSAN_STALL" swift test --skip-build --sanitize=thread --scratch-path "$scratch" \
        "${filters[@]}"
    status=$?
    if [ "$status" -eq 124 ]; then
        result "tsan run" fail "no output for ${TSAN_STALL} s, stack in logs/tsan-tests.log.hang.txt"
    fi

    # The races, and the tests. A race does not fail the test it happens in
    # (the run's exit status is TSan's 66, not a test failure), so both are read
    # from the log.
    local races_out=$DIR/logs/tsan-races.txt
    "${HELPER[@]}" races --root "$ROOT" --results "$DIR/tsan.results.tsv" "$tests_log" > "$races_out"
    local unique total
    read -r _ unique total < <(head -1 "$races_out")
    "${HELPER[@]}" tests "$tests_log" >> "$DIR/tsan.results.tsv"
    local timing_rules
    timing_rules=$("${HELPER[@]}" timing "$ALLOW")
    local set_aside=""
    while read -r rule; do
        [ -z "$rule" ] && continue
        if grep -qF "$rule${TAB}fail${TAB}" "$DIR/tsan.results.tsv"; then
            set_aside="$set_aside $rule"
            sed -i '' "s|^\($rule\)${TAB}fail${TAB}.*|\1${TAB}not run${TAB}a real-time bound, failed by the sanitizer's slowdown and not counted|" "$DIR/tsan.results.tsv"
        fi
    done <<<"$timing_rules"
    local ran failed
    # test classes of the list that ran nothing (renamed or deleted)
    if [ "${DESK_LANES_TSAN_APP:-}" != all ]; then
        for class in "${TSAN_APP_CLASSES[@]}"; do
            grep -q "Test Suite '$class' started" "$tests_log" \
                || result "tsan list: $class" fail "ran no test: renamed or deleted? update TSAN_APP_CLASSES in scripts/desk-lanes.sh"
        done
    fi
    ran=$(grep -v "^tsan " "$DIR/tsan.results.tsv" | grep -cE "${TAB}(pass|fail)${TAB}")
    failed=$(grep -v "^tsan " "$DIR/tsan.results.tsv" | grep -cE "${TAB}fail${TAB}")
    # the run itself (stalled) or the class list (a name that ran nothing)
    local broken
    broken=$(grep -E "^tsan (run|list)" "$DIR/tsan.results.tsv" | grep -cE "${TAB}fail${TAB}")

    {
        echo "Thread Sanitizer, $DATE"
        echo "Core: all of it. $app_note."
        echo "Real-time bounds failed by the slowdown, not counted:${set_aside:- none}"
        echo "$ran tests ran; $unique distinct race report(s) ($total in all)."
        echo ""
        if [ "${unique:-0}" -gt 0 ]; then
            echo "Races, by their top frame (the first frame in this repository after |):"
            grep -E "^RACE " "$races_out" | sed 's/^/  /'
            echo ""
            echo "Full reports: logs/tsan-races.txt"
        else
            echo "No data race was reported."
        fi
        grep -E "${TAB}fail${TAB}" "$DIR/tsan.results.tsv" | grep -v "^tsan race" | sed 's/^/  failed: /'
    } > "$DIR/tsan.txt"

    if [ "$ran" -eq 0 ]; then
        finish_lane failed "no test ran under the sanitizer (see logs/tsan-tests.log)"
    elif [ "${unique:-0}" -gt 0 ]; then
        finish_lane failed "$unique distinct data race(s) in $ran tests: tsan.txt"
    elif [ "$broken" -gt 0 ]; then
        finish_lane failed "the run stalled or a listed class ran nothing: tsan.txt"
    elif [ "$failed" -gt 0 ]; then
        finish_lane failed "$failed of $ran tests failed under the sanitizer: tsan.txt"
    else
        finish_lane ok "no race in $ran tests (Core, $app_note)"
    fi
}

# --------------------------------------------------------------- coverage ----
lane_coverage() {
    begin_lane coverage
    local scratch=.build-cov log
    log=$DIR/logs/coverage-build.log
    if ! swift build --build-tests --enable-code-coverage --scratch-path "$scratch" > "$log" 2>&1; then
        finish_lane failed "the tests do not build for coverage: $(first_error "$log")"
        return
    fi
    # One serial `swift test`: the shards test.sh runs would each write their
    # own profile, and this lane is not in a hurry. Raw profiles of an earlier
    # run are cleared so the report is this run's.
    find "$scratch" -name "*.profraw" -delete 2>/dev/null
    rm -f "$scratch"/*/debug/codecov/default.profdata "$scratch"/out/Products/Debug/codecov/default.profdata 2>/dev/null
    local tests_log=$DIR/logs/coverage-tests.log status
    local filter=() partial=""
    if [ -n "${DESK_LANES_COVERAGE_FILTER:-}" ]; then
        filter=(--filter "$DESK_LANES_COVERAGE_FILTER")
        partial=" (only tests matching $DESK_LANES_COVERAGE_FILTER: a part of the suite)"
    fi
    run_watched "$tests_log" "$COVERAGE_STALL" swift test --skip-build --enable-code-coverage --scratch-path "$scratch" \
        ${filter[@]+"${filter[@]}"}
    status=$?
    "${HELPER[@]}" tests "$tests_log" > "$DIR/coverage.results.tsv"
    if [ "$status" -eq 124 ]; then
        result "coverage run" fail "no output for ${COVERAGE_STALL} s, stack in logs/coverage-tests.log.hang.txt"
    fi
    local ran failed
    ran=$(grep -cE "${TAB}(pass|fail)${TAB}" "$DIR/coverage.results.tsv")
    failed=$(grep -cE "${TAB}fail${TAB}" "$DIR/coverage.results.tsv")

    local bin profdata export=$SCRATCH/coverage-export.json
    bin=$(swift build --build-tests --enable-code-coverage --scratch-path "$scratch" --show-bin-path 2>/dev/null)
    profdata=$(swift test --skip-build --enable-code-coverage --scratch-path "$scratch" --show-codecov-path 2>/dev/null \
        | head -1 | sed -E 's|/[^/]+\.json$|/default.profdata|')
    [ -f "$profdata" ] || profdata=$bin/codecov/default.profdata
    local objects=()
    for bundle in "$bin"/*.xctest; do
        for binary in "$bundle/Contents/MacOS/"*; do [ -f "$binary" ] && objects+=("$binary"); done
    done
    if [ ! -f "$profdata" ] || [ ${#objects[@]} -eq 0 ]; then
        finish_lane failed "no profile data after the run (looked for $profdata): logs/coverage-tests.log"
        return
    fi
    local args=(-instr-profile="$profdata" "${objects[0]}")
    for binary in "${objects[@]:1}"; do args+=(-object "$binary"); done
    if ! xcrun llvm-cov export "${args[@]}" > "$export" 2> "$DIR/logs/coverage-export.err"; then
        finish_lane failed "llvm-cov could not read the profile: logs/coverage-export.err"
        return
    fi
    if ! "${HELPER[@]}" coverage "$export" --root "$ROOT" > "$DIR/coverage.txt"; then
        finish_lane failed "the export holds nothing under Sources/ (coverage.txt)"
        return
    fi
    local headline
    headline=$(head -1 "$DIR/coverage.txt" | sed -E 's/^Coverage of Sources\/ by the whole suite: //; s/\. A report.*//')$partial
    # Test failures are the other lanes' business as much as this one's, but a
    # suite that failed while being measured is a measure of a part: say so.
    if [ "$failed" -gt 0 ]; then
        finish_lane failed "$headline; $failed of $ran tests failed in this run (coverage.results.tsv)"
    elif [ "$ran" -eq 0 ]; then
        finish_lane failed "no test ran (logs/coverage-tests.log)"
    else
        finish_lane ok "$headline; $ran tests ran"
    fi
}

# ------------------------------------------------------------------- live ----
# One row per live test: where it lives, what it is, what the test decides on,
# and what it needs of the desk. The lane runs every `any` rule in
# Tests/allowed-skips.txt, and fails when a rule has no row here (a new live
# test that nothing would run) or a row names a test that is gone.
#   bundle | Class[/test] | environment | needs
#   needs: idle (it moves focus: wait for a quiet keyboard), model (the
#   Standard model in the Hugging Face cache), person (someone must speak),
#   download (3.6 GB), qwen (a Qwen3-ASR folder)
live_recipes() {
    cat <<'RECIPES'
core|WindowModelLiveTests|LODESTAR_LIVE_MODEL=1|idle
app|EditorAccuracyLiveTests/testTheModelAgainstTheFixture|LODESTAR_EDITOR_LIVE=standard|model
app|EditorRegionLiveTests|LODESTAR_EDITOR_LIVE=standard|model
app|IntentPassLiveTests|LODESTAR_INTENT_LIVE=gemma|model
app|EditorConformanceTests|LODESTAR_EDITOR_CONFORMANCE=1|idle
app|ClipboardBenchTests|LODESTAR_CLIPBOARD_BENCH=1 LODESTAR_CLIPBOARD_BENCH_OUT=@REPORT@/clipboard-bench.txt|
app|EditorCostTests|LODESTAR_EDITOR_MEASURE=60|
app|EditorWatchProbeTests|LODESTAR_EDITOR_MEASURE=60|
app|RealWindowDeskTests|LODESTAR_DESK_WINDOWS=1|idle
app|MicBridgeLiveTests||person
app|EditorDownloadLiveTests|LODESTAR_EDITOR_DOWNLOAD=standard|download
app|QwenEarTests/testTokenizerFromTheFolderMatchesTransformers|QWEN_ASR_FOLDER=@QWEN@|qwen
RECIPES
}

# The test list says these `any` entries are not checks to run: the gallery is
# drawn for a person to look at (scripts/render-gallery.sh).
LIVE_NOT_CHECKS="RenderGalleryTests"

# The pinned Standard model, in the Hugging Face cache where a test run (which
# has a home of its own) looks for it.
standard_model_here() {
    local pin repo revision
    pin=$("${HELPER[@]}" pin Sources/lodestar/EditorDownload.swift standard) || return 2
    repo=${pin% *}
    revision=${pin#* }
    [ -e "$HOME/.cache/huggingface/hub/models--${repo//\//--}/snapshots/$revision/model.safetensors" ]
}

qwen_folder_here() {
    if [ -n "${QWEN_ASR_FOLDER:-}" ] && [ -d "$QWEN_ASR_FOLDER" ]; then echo "$QWEN_ASR_FOLDER"; return 0; fi
    local found
    found=$(ls -d "$HOME"/.cache/huggingface/hub/models--*Qwen3-ASR*/snapshots/* 2>/dev/null | head -1)
    [ -n "$found" ] && echo "$found"
}

# bundle_of CLASS: core or app, by where the class is declared.
bundle_of() {
    if grep -rqE "class $1\b" Tests/LodestarCoreTests; then echo core; else echo app; fi
}

# run_xctest BUNDLE TARGET ENV...: one xctest process for a class or a test, its
# rows into the results. Returns 0 if the process ran, whatever the tests said.
run_xctest() {
    local which=$1 target=$2
    shift 2
    local bundle prefix log
    if [ "$which" = core ]; then bundle=$CORE_BUNDLE; prefix=LodestarCoreTests; else bundle=$APP_BUNDLE; prefix=LodestarAppTests; fi
    log=$DIR/logs/live-$(tr '/' '-' <<<"$target").log
    run_watched "$log" "$LIVE_STALL" env "$@" xcrun xctest -XCTest "$prefix.$target" "$bundle"
    local status=$?
    local rows
    rows=$("${HELPER[@]}" tests "$log")
    if [ "$status" -eq 124 ]; then
        result "$target" fail "no output for ${LIVE_STALL} s, stack in logs/$(basename "$log").hang.txt"
    elif [ -z "$rows" ]; then
        result "$target" fail "no such test in the bundle: renamed or deleted? fix the row in scripts/desk-lanes.sh"
    else
        printf '%s\n' "$rows" >> "$DIR/live.results.tsv"
    fi
}

lane_live() {
    begin_lane live
    local log=$DIR/logs/live-build.log
    if ! swift build --build-tests > "$log" 2>&1; then
        finish_lane failed "the tests do not build: $(first_error "$log")"
        return
    fi
    local bin
    bin=$(swift build --show-bin-path)
    if ! find_bundles "$bin"; then
        finish_lane failed "no test bundles in $bin"
        return
    fi

    local row which target envs needs class idle
    # --- the live tests
    while IFS='|' read -r which target envs needs; do
        [ -z "$which" ] && continue
        class=${target%%/*}
        envs=${envs//@REPORT@/$DIR}
        case "$needs" in
            person)
                result "$target" "not run" "needs a person to say five words at the tone (LODESTAR_LIVE_MIC=1, by hand)"
                continue ;;
            download)
                if [ -z "${DESK_LANES_DOWNLOAD:-}" ]; then
                    result "$target" "not run" "downloads 3.6 GB on every run: DESK_LANES_DOWNLOAD=1 to include it"
                    continue
                fi ;;
            model)
                if ! standard_model_here; then
                    result "$target" "not run" "the Standard model at its pinned revision is not in ~/.cache/huggingface (a test run looks nowhere else)"
                    continue
                fi ;;
            qwen)
                local folder
                if folder=$(qwen_folder_here); then
                    envs=${envs//@QWEN@/$folder}
                else
                    result "$target" "not run" "no Qwen3-ASR folder: set QWEN_ASR_FOLDER to one"
                    continue
                fi ;;
            idle)
                idle=$(idle_seconds)
                if [ "${idle:-0}" -lt 5 ] && [ -z "${FORCE:-}" ]; then
                    result "$target" "not run" "the keyboard was used ${idle}s ago and this test takes focus (FORCE=1 to run anyway)"
                    continue
                fi ;;
        esac
        echo "  $target"
        # shellcheck disable=SC2086
        run_xctest "$which" "$target" $envs
    done < <(live_recipes)

    # --- the allowlist's `any` rules, each with a row (or not a check)
    local rule covered
    while read -r rule; do
        [ -z "$rule" ] && continue
        class=${rule%%.*}
        covered=0
        case " $LIVE_NOT_CHECKS " in *" $class "*) continue ;; esac
        while IFS='|' read -r which target envs needs; do
            [ "${target%%/*}" = "$class" ] && covered=1
        done < <(live_recipes)
        [ "$covered" -eq 0 ] && result "recipe: $rule" fail "an \`any\` rule in $ALLOW that this lane has no row for: add one to live_recipes in scripts/desk-lanes.sh (or to LIVE_NOT_CHECKS)"
    done < <("${HELPER[@]}" any "$ALLOW")

    # --- the timing lane: real-time properties, on a desk that has just been
    # quiet. Each is one process, so a slow one cannot bleed into the next.
    local timing_rules
    timing_rules=$("${HELPER[@]}" timing "$ALLOW")
    if [ -z "$timing_rules" ]; then
        result "timing lane" fail "no \`ci\` rules after the \"timing lane\" comment in $ALLOW: the comment moved?"
    fi
    while read -r rule; do
        [ -z "$rule" ] && continue
        class=${rule%%.*}
        echo "  timing: $rule"
        run_xctest "$(bundle_of "$class")" "$class/${rule#*.}"
    done <<<"$timing_rules"

    # --- the dictation evaluation
    echo "  dictation evaluation"
    dictation_eval "$bin"

    # --- the report
    {
        echo "Live tests, $DATE"
        echo ""
        printf '%-8s %s\n' "result" "test"
        awk -F'\t' '{ printf "%-8s %s%s\n", $2, $1, ($3 != "" ? "  (" $3 ")" : "") }' "$DIR/live.results.tsv"
        echo ""
        [ -f "$DIR/clipboard-bench.txt" ] && echo "The clipboard bench table is in clipboard-bench.txt."
        [ -f "$DIR/dictation-eval.txt" ] && echo "The dictation evaluation's scores are in dictation-eval.txt."
    } > "$DIR/live.txt"

    local passed failed skipped
    passed=$(grep -cE "${TAB}pass${TAB}" "$DIR/live.results.tsv")
    failed=$(grep -cE "${TAB}fail${TAB}" "$DIR/live.results.tsv")
    skipped=$(grep -cE "${TAB}not run${TAB}" "$DIR/live.results.tsv")
    if [ "$failed" -gt 0 ]; then
        finish_lane failed "$failed failed, $passed passed, $skipped not run: live.txt"
    else
        finish_lane ok "$passed passed, $skipped not run: live.txt"
    fi
}

# The dictation evaluation (scripts/dictation-eval): macOS `say` speaks the
# corpus in six voices, `probe dictation` transcribes it with the draft's own
# recognizer and settles it with the draft's own pipeline, and score.py scores
# it. It writes into its own folder, so it runs in a copy in the scratch
# folder. The synthetic set only: the human clips are fetched from the network
# (fetch_human.py), which this lane does not do.
dictation_eval() {
    local work=$SCRATCH/dictation-eval probe=$1/probe
    rm -rf "$work"
    mkdir -p "$work"
    cp -R scripts/dictation-eval/. "$work/"
    if [ ! -x "$probe" ]; then
        result "dictation-eval" fail "no probe binary at $probe"
        return
    fi
    if ! (cd "$work" && python3 build_synth.py) > "$DIR/logs/dictation-synth.log" 2>&1; then
        result "dictation-eval" fail "build_synth.py failed: logs/dictation-synth.log"
        return
    fi
    "${HELPER[@]}" names "$work/corpus_src.py" > "$work/names.txt"
    run_watched "$DIR/logs/dictation-transcribe.log" 600 "$probe" dictation transcribe \
        --manifest "$work/manifest.json" --root "$work" --out "$work/runs.jsonl"
    local status=$?
    if [ "$status" -ne 0 ]; then
        local why
        why=$(tail -1 "$DIR/logs/dictation-transcribe.log" | cut -c1-160)
        if grep -qiE "not authori|denied|not allowed|permission|assets|not available|unsupported locale" "$DIR/logs/dictation-transcribe.log"; then
            result "dictation-eval" "not run" "the recognizer is not usable from here: $why"
        else
            result "dictation-eval" fail "probe dictation transcribe exited $status: $why"
        fi
        return
    fi
    if ! "$probe" dictation settle --runs "$work/runs.jsonl" --words "$work/names.txt" --out "$work/hyps.json" \
        > "$DIR/logs/dictation-settle.log" 2>&1; then
        result "dictation-eval" fail "probe dictation settle failed: logs/dictation-settle.log"
        return
    fi
    if ! python3 "$work/score.py" "$work/hyps.json" --manifest "$work/manifest.json" --json "$DIR/dictation-eval.json" \
        > "$DIR/dictation-eval.txt" 2>&1; then
        result "dictation-eval" fail "score.py failed: dictation-eval.txt"
        return
    fi
    local all
    all=$(awk '$1 == "ALL" { print "items " $2 ", wer " $3 ", names exact " $6 ", pause breaks " $9 }' "$DIR/dictation-eval.txt")
    result "dictation-eval" pass "${all:-scored}"
}

# ------------------------------------------------------------------- main ----
overall=0
for lane in "${lanes[@]}"; do
    case "$lane" in
        tsan) lane_tsan || overall=1 ;;
        coverage) lane_coverage || overall=1 ;;
        live) lane_live || overall=1 ;;
        summary) ;;
    esac
done
echo ""
"${HELPER[@]}" summary "$REPORTS" "$DATE" | tee "$DIR/summary.txt"
summary_status=${PIPESTATUS[0]}
# Asked only for the summary, the exit status is the summary's: 1 when a lane
# of the day failed.
[ "${lanes[*]}" = summary ] && overall=$summary_status
exit "$overall"
