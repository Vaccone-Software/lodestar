#!/usr/bin/env python3
"""What scripts/test.sh reads out of the shards' logs: one result per test
as JUnit XML, and the quarantine rules. Standard library only, and nothing
here builds or runs a test, so scripts/test-sh-selftest.sh can run it on
fixture logs.

  test-results.py junit --out FILE [--quarantine FILE] [--today YYYY-MM-DD] LOG...
      Parses xctest's own log lines (every test writes "started" and then
      "passed", "failed" or "skipped" with its seconds; a failure writes
      "file:line: error: -[Bundle.Class test] : message" first, a skip
      "file:line: -[Bundle.Class test] : Test skipped - reason") and writes
      one testcase per test, passes too. A message that runs over several
      lines keeps its first. Prints, for test.sh to act on:

        LOG <log> executed=N parsed=N failed=N quarantined=N
        FAIL <Class.test> <message>          a failure no quarantine excuses
        QUARANTINED <Class.test> <expires> <reason>
        PROBLEM <what>                       the results cannot be trusted

      A test that started and never finished (the process died or was
      stopped inside it) is a FAIL however it is listed: quarantine excuses
      a recorded failure, never a crash. PROBLEM: the tests parsed from a
      log are not the number its own summary says were executed.

  test-results.py quarantine FILE TESTS --today YYYY-MM-DD
      Checks Tests/quarantine.txt against `swift test list`'s output.
      Prints PROBLEM lines, and exits 1 when there are any.
"""
import argparse
import datetime
import re
import sys
import xml.etree.ElementTree as ET
from collections import OrderedDict, defaultdict

# The longest a test may be parked, counted from today. Short on purpose: a
# quarantine is a deadline to fix the test, not a place to keep it.
MAX_DAYS = 14

STARTED = re.compile(r"Test Case '-\[(\S+) (\S+)\]' started\.")
ENDED = re.compile(r"Test Case '-\[(\S+) (\S+)\]' (passed|failed|skipped) \((\d+(?:\.\d+)?) seconds\)")
ERROR = re.compile(r"^(.*?):(\d+): error: -\[(\S+) (\S+)\] : (.*)$")
SKIPPED = re.compile(r"^(.*?):(\d+): -\[(\S+) (\S+)\] : Test skipped(?: - (.*))?$")
EXECUTED = re.compile(r"^\s+Executed (\d+) tests?")
# Characters XML 1.0 cannot carry (a log may hold terminal escapes).
ILLEGAL = re.compile("[\x00-\x08\x0b\x0c\x0e-\x1f￾￿]")


def short(name):
    """LodestarAppTests.SlabTests + testX -> SlabTests.testX, the name the
    allowlists use."""
    return name.split(".", 1)[-1]


def clean(text):
    return ILLEGAL.sub("?", text)


def parse_quarantine(path):
    """(entries, problems). An entry: name -> (expires date, reason, line)."""
    entries, problems = OrderedDict(), []
    try:
        lines = open(path).read().splitlines()
    except OSError as e:
        return entries, [f"cannot read {path}: {e}"]
    for number, raw in enumerate(lines, 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split(None, 2)
        where = f"{path}:{number}"
        if len(parts) < 3:
            problems.append(f"{where}: want '<Class>.<test> <expires YYYY-MM-DD> <reason>', got: {line}")
            continue
        name, expires, reason = parts
        if not re.fullmatch(r"[A-Za-z0-9_]+\.[A-Za-z0-9_]+", name):
            problems.append(f"{where}: '{name}' is not one Class.test (no wildcards, no bundle)")
            continue
        try:
            when = datetime.date.fromisoformat(expires)
        except ValueError:
            problems.append(f"{where}: '{expires}' is not a date, YYYY-MM-DD")
            continue
        if name in entries:
            problems.append(f"{where}: {name} is listed twice")
            continue
        entries[name] = (when, reason, number)
    return entries, problems


def check_quarantine(path, tests_path, today):
    entries, problems = parse_quarantine(path)
    listed = set()
    for line in open(tests_path):
        line = line.strip()
        if "/" in line:
            cls, test = line.split("/", 1)
            listed.add(f"{short(cls)}.{test}")
    limit = today + datetime.timedelta(days=MAX_DAYS)
    for name, (when, reason, number) in entries.items():
        where = f"{path}:{number}"
        if when < today:
            problems.append(f"{where}: {name} expired on {when}: fix the test or delete the entry")
        elif when > limit:
            problems.append(f"{where}: {name} expires {when}, more than {MAX_DAYS} days from {today} (latest {limit})")
        if name not in listed:
            problems.append(f"{where}: {name} is not in the test list: renamed or deleted? fix or delete the entry")
    return problems


def parse_log(path):
    """The tests of one shard's log, in the order they started: a dict of
    full name -> {class, test, status, time, errors, skip}. status is
    passed, failed, skipped, or None for a test that never finished."""
    tests, executed = OrderedDict(), None
    for line in open(path, errors="replace"):
        line = line.rstrip("\n")
        # Searched, not anchored: a test's own output with no newline in it
        # ends up in front of the next line xctest writes.
        m = STARTED.search(line)
        if m:
            key = f"{m.group(1)} {m.group(2)}"
            tests.setdefault(key, dict(cls=m.group(1), test=m.group(2), status=None, time=0.0, errors=[], skip=None))
            continue
        m = ENDED.search(line)
        if m:
            key = f"{m.group(1)} {m.group(2)}"
            t = tests.setdefault(key, dict(cls=m.group(1), test=m.group(2), status=None, time=0.0, errors=[], skip=None))
            t["status"], t["time"] = m.group(3), float(m.group(4))
            continue
        m = ERROR.match(line)
        if m:
            key = f"{m.group(3)} {m.group(4)}"
            t = tests.setdefault(key, dict(cls=m.group(3), test=m.group(4), status=None, time=0.0, errors=[], skip=None))
            t["errors"].append((m.group(1), m.group(2), m.group(5)))
            continue
        m = SKIPPED.match(line)
        if m:
            key = f"{m.group(3)} {m.group(4)}"
            if key in tests:
                tests[key]["skip"] = m.group(5) or ""
            continue
        m = EXECUTED.match(line)
        if m:
            executed = int(m.group(1))
    return tests, executed


def junit(args):
    entries, problems = parse_quarantine(args.quarantine) if args.quarantine else ({}, [])
    today = datetime.date.fromisoformat(args.today) if args.today else datetime.date.today()
    out = []
    suites = OrderedDict()
    for log in args.logs:
        tests, executed = parse_log(log)
        finished = [t for t in tests.values() if t["status"]]
        failed = quarantined = 0
        for t in tests.values():
            name = f"{short(t['cls'])}.{t['test']}"
            quarantine = entries.get(name)
            case = ET.Element("testcase", classname=t["cls"], name=t["test"], time=f"{t['time']:.3f}")
            if t["status"] is None:
                text = "started and never finished: the process died or was stopped inside this test"
                ET.SubElement(case, "error", message=text, type="Unfinished").text = text
                out.append(f"FAIL {name} {text}")
                failed += 1
            elif t["status"] == "failed":
                errors = t["errors"] or [("", "", "failed, and no error line for it in the log")]
                for file, line, message in errors:
                    kind = message.split(" ", 1)[0] if message.startswith("XCT") else "failure"
                    text = (f"{file}:{line}: " if file else "") + message
                    ET.SubElement(case, "failure", message=clean(message)[:300], type=kind).text = clean(text)
                if quarantine and quarantine[0] >= today:
                    props = ET.SubElement(case, "properties")
                    ET.SubElement(props, "property", name="quarantined", value=f"until {quarantine[0]}: {quarantine[1]}")
                    out.append(f"QUARANTINED {name} {quarantine[0]} {quarantine[1]}")
                    quarantined += 1
                else:
                    out.append(f"FAIL {name} {errors[0][2][:200]}")
                    failed += 1
            elif t["status"] == "skipped":
                ET.SubElement(case, "skipped", message=clean(t["skip"] or ""))
            suites.setdefault(t["cls"], []).append(case)
        out.append(f"LOG {log} executed={executed} parsed={len(finished)} failed={failed} quarantined={quarantined}")
        if executed is None:
            out.append(f"PROBLEM {log} has no 'Executed N tests' summary")
        elif executed != len(finished):
            out.append(f"PROBLEM {log}: its summary says {executed} tests ran and {len(finished)} were read from it, so the results file is missing some")

    root = ET.Element("testsuites", name="lodestar")
    totals = defaultdict(float)
    for cls, cases in suites.items():
        suite = ET.SubElement(root, "testsuite", name=cls)
        counts = defaultdict(int)
        seconds = 0.0
        for case in cases:
            suite.append(case)
            seconds += float(case.get("time"))
            counts["tests"] += 1
            counts["failures"] += 1 if case.find("failure") is not None else 0
            counts["errors"] += 1 if case.find("error") is not None else 0
            counts["skipped"] += 1 if case.find("skipped") is not None else 0
        for key in ("tests", "failures", "errors", "skipped"):
            suite.set(key, str(counts[key]))
            totals[key] += counts[key]
        suite.set("time", f"{seconds:.3f}")
        totals["time"] += seconds
    for key in ("tests", "failures", "errors", "skipped"):
        root.set(key, str(int(totals[key])))
    root.set("time", f"{totals['time']:.3f}")
    ET.indent(root)
    ET.ElementTree(root).write(args.out, encoding="UTF-8", xml_declaration=True)
    print("\n".join(out))
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    j = sub.add_parser("junit")
    j.add_argument("--out", required=True)
    j.add_argument("--quarantine")
    j.add_argument("--today")
    j.add_argument("logs", nargs="+")
    q = sub.add_parser("quarantine")
    q.add_argument("file")
    q.add_argument("tests")
    q.add_argument("--today", required=True)
    args = parser.parse_args()
    if args.command == "junit":
        return junit(args)
    problems = check_quarantine(args.file, args.tests, datetime.date.fromisoformat(args.today))
    for p in problems:
        print(f"PROBLEM {p}")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
