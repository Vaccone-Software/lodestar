#!/usr/bin/env python3
"""What scripts/desk-lanes.sh reads out of the logs its lanes leave: the data
races a Thread Sanitizer run reports, the coverage of the risky code, and the
guard that says a lane has been failing the same thing run after run.
Standard library only, and nothing here builds or runs a test, so
scripts/desk-lanes-selftest.sh can run it on fixture logs.

  desk-lanes.py races [--root DIR] [--results FILE] LOG...
      Every "WARNING: ThreadSanitizer" block in the logs, deduplicated by the
      block's own SUMMARY line (the kind of report and its top frame). With
      --results, each is also appended there as a failed row for the guard.
      Prints

        RACES <unique> <total>
        RACE <count> <summary> | <top frame> | <first frame in this repository>
        <one example block, indented>

  desk-lanes.py tests LOG...
      The tests the logs ran, from xctest's own lines (the parser is
      test-results.py's): one tab-separated line per test,
      "Class.test<TAB>pass|fail|not run<TAB>message". A test that started and
      never finished is a fail; a skip is "not run" with its reason.

  desk-lanes.py coverage EXPORT.json --root DIR
      `llvm-cov export` of a suite, read as a report: every file under
      DIR/Sources with its lines, then the areas the review names (taps, the
      updater, sealed storage, deletion paths, migrations) with their
      uncovered lines and the functions never called. No threshold, no gate.

  desk-lanes.py timing ALLOWED_SKIPS
  desk-lanes.py any ALLOWED_SKIPS
      The tests the allowlist places under its "timing lane" comment (the
      `ci` rules after it), and every `any` rule (the live tests), one
      Class.test or Class.* per line.

  desk-lanes.py pin SWIFT_FILE NAME
      "repo revision" of the model manifest `static let NAME` in the file:
      the pinned model a live test needs in the Hugging Face cache.

  desk-lanes.py names CORPUS_SRC.py
      The names in corpus_src.py's USER_NAMES, one per line, for the
      dictation evaluation's word list.

  desk-lanes.py summary REPORTS_DIR DATE
      The one-screen summary of REPORTS_DIR/DATE, and the guard: a name that
      failed in a lane's results (<lane>.results.tsv) and failed in the
      same lane's earlier runs too, back to the first of them, is said to be
      failing since that date. An earlier run where the name passed ends the
      chain; one where it was not run (no microphone, no Accessibility) is
      skipped over, since it says nothing either way. Prints, and exits 1
      when a lane failed.
"""
import importlib.util
import json
import os
import re
import subprocess
import sys
from collections import OrderedDict

HERE = os.path.dirname(os.path.abspath(__file__))

# Where a lane's files are: <lane>.status is "ok|failed|not run <TAB> seconds
# <TAB> note"; <lane>.results.tsv is "name <TAB> pass|fail|not run <TAB> note".
LANES = ("tsan", "coverage", "live")


def results_parser():
    """test-results.py's log parser (the name has a hyphen, so it is loaded
    by path)."""
    spec = importlib.util.spec_from_file_location("test_results", os.path.join(HERE, "test-results.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


# ------------------------------------------------------------------ races ----
# TSan prints a Swift frame as "#1 closure #1 in Foo.bar() Foo.swift:12 (Module:arm64+0x1f)":
# the file by its name alone, not its path.
FRAME = re.compile(r"^\s*#\d+ (?P<fn>.*?) (?P<file>[^\s()]+\.swift)(?::(?P<line>\d+))? \(")
FRAME_ANY = re.compile(r"^\s*#\d+ (?P<fn>\S.*?)(?: \(| \S+:\d+|$)")


def race_blocks(text):
    """(kind, summary, lines) for each report. A block runs from its WARNING
    line to its SUMMARY line, or to the next report or the end of the log
    when a process died in the middle of writing one."""
    blocks, current = [], None
    for line in text.splitlines():
        m = re.search(r"WARNING: ThreadSanitizer: (.*?)(?: \(pid=\d+\))?$", line)
        if m:
            if current:
                blocks.append(current)
            current = dict(kind=m.group(1).strip(), summary=None, lines=[line])
            continue
        if current is None:
            continue
        current["lines"].append(line)
        m = re.search(r"SUMMARY: ThreadSanitizer: (.*)$", line)
        if m:
            current["summary"] = m.group(1).strip()
            blocks.append(current)
            current = None
    if current:
        blocks.append(current)
    return blocks


def top_frame(block):
    for line in block["lines"]:
        m = FRAME_ANY.match(line)
        if m:
            m2 = FRAME.match(line)
            where = m2.group("file") + (":" + m2.group("line") if m2.group("line") else "") if m2 else ""
            return f"{m.group('fn')} {where}".strip()
    return "?"


def source_index(root):
    """Swift file name -> its paths under root/Sources and root/Tests."""
    index = {}
    for top in ("Sources", "Tests"):
        for folder, _, names in os.walk(os.path.join(root, top)):
            for name in names:
                if name.endswith(".swift"):
                    index.setdefault(name, []).append(os.path.relpath(os.path.join(folder, name), root))
    return index


def repo_frame(block, index):
    """The first frame in a file of this repository's Sources or Tests, which
    is where the fix is. TSan names the file without its folder, so the name
    is looked up (a name in two folders gives both)."""
    for line in block["lines"]:
        m = FRAME.match(line)
        if m and m.group("file") in index:
            return f"{' | '.join(index[m.group('file')])}:{m.group('line') or '?'} {m.group('fn')}"
    return "no frame in Sources or Tests"


def races(args):
    root, results = ".", None
    for flag in ("--root", "--results"):
        if flag in args:
            at = args.index(flag)
            value = args[at + 1]
            args = args[:at] + args[at + 2:]
            if flag == "--root":
                root = value
            else:
                results = value
    index = source_index(root)
    unique = OrderedDict()
    total = 0
    for path in args:
        with open(path, errors="replace") as handle:
            text = handle.read()
        for block in race_blocks(text):
            total += 1
            key = block["summary"] or f"{block['kind']} {top_frame(block)}"
            if key in unique:
                unique[key]["count"] += 1
            else:
                unique[key] = dict(count=1, kind=block["kind"], top=top_frame(block),
                                   repo=repo_frame(block, index), lines=block["lines"], key=key)
    print(f"RACES {len(unique)} {total}")
    if results:
        with open(results, "a") as out:
            for entry in unique.values():
                out.write(f"tsan race: {entry['key']}\tfail\t{entry['repo']}\n")
    for entry in unique.values():
        print(f"RACE {entry['count']} {entry['key']} | {entry['top']} | {entry['repo']}")
        for line in entry["lines"][:40]:
            print("    " + line)
    return 0


# ------------------------------------------------------------------ tests ----
def tests(paths):
    parser = results_parser()
    merged = OrderedDict()
    for path in paths:
        parsed, _ = parser.parse_log(path)
        merged.update(parsed)
    for t in merged.values():
        name = f"{t['cls'].split('.', 1)[-1]}.{t['test']}"
        if t["status"] == "passed":
            status, note = "pass", ""
        elif t["status"] == "skipped":
            status, note = "not run", t["skip"] or ""
        elif t["status"] == "failed":
            first = t["errors"][0] if t["errors"] else None
            status, note = "fail", f"{os.path.basename(first[0])}:{first[1]} {first[2]}" if first else ""
        else:
            status, note = "fail", "started and never finished (the process died or was stopped inside it)"
        print(f"{name}\t{status}\t{note.replace(chr(9), ' ').replace(chr(10), ' ')[:300]}")
    return 0


# --------------------------------------------------------------- coverage ----
# The risky code the review names. A file is in an area by its name; the two
# function patterns catch the rest: a deletion or a migration in any file.
AREAS = OrderedDict([
    ("taps", dict(files=r"(Tap|KeyboardListener|WheelListener|HotkeyEngine|HealthMonitor|MouseScroll)\w*\.swift$",
                  functions=None)),
    ("updater", dict(files=r"(Update\w*|Updater)\.swift$", functions=None)),
    ("sealed storage", dict(files=r"(Sealed\w*|\w*Sealed|SealedIO|Vault|DurableFile|PrivateFile|OwnerOnly|StateFiles)\.swift$",
                            functions=None)),
    ("deletion paths", dict(files=r"(Uninstall\w*|Retention)\.swift$",
                            functions=r"\b(delete|deleting|remove|removing|clear|purge|wipe|trash|evict|forget|erase)\w*")),
    ("migrations", dict(files=r"\w*(Migration|ClipboardV1)\.swift$", functions=r"migrat")),
])


def demangle(names):
    """Swift names, readable. A missing demangler leaves them as they are."""
    if not names:
        return {}
    try:
        out = subprocess.run(["xcrun", "swift-demangle", "--simplified"], input="\n".join(names) + "\n",
                             capture_output=True, text=True, timeout=300).stdout.split("\n")
        if len(out) >= len(names):
            return dict(zip(names, out))
    except (OSError, subprocess.SubprocessError):
        pass
    return {n: n for n in names}


def percent(covered, total):
    return f"{100.0 * covered / total:5.1f}%" if total else "    -"


def coverage(export_path, root):
    with open(export_path) as handle:
        data = json.load(handle)["data"][0]
    prefix = os.path.join(os.path.realpath(root), "Sources") + os.sep
    files = OrderedDict()
    for f in sorted(data["files"], key=lambda f: f["filename"]):
        name = os.path.realpath(f["filename"]) if os.path.exists(f["filename"]) else f["filename"]
        if name.startswith(prefix):
            lines, funcs = f["summary"]["lines"], f["summary"]["functions"]
            files[name[len(prefix) - len("Sources/"):]] = dict(
                lines=lines["count"], covered=lines["covered"], funcs=funcs["count"], funcs_covered=funcs["covered"])
    if not files:
        print(f"no file under {prefix} in the export")
        return 1
    total = sum(f["lines"] for f in files.values())
    covered = sum(f["covered"] for f in files.values())
    print(f"Coverage of Sources/ by the whole suite: {covered} of {total} lines, {percent(covered, total).strip()}"
          f" in {len(files)} files. A report, not a gate.\n")

    # Never called: the functions of the risky areas with a count of zero.
    uncalled = OrderedDict()
    for fn in data.get("functions", []):
        if fn["count"] != 0 or not fn.get("filenames"):
            continue
        for name in fn["filenames"][:1]:
            real = os.path.realpath(name) if os.path.exists(name) else name
            if real.startswith(prefix):
                uncalled.setdefault(real[len(prefix) - len("Sources/"):], []).append(fn["name"])
    readable = demangle(sorted({n for names in uncalled.values() for n in names}))

    def short(name):
        pretty = re.sub(r"^\S+\.", "", readable.get(name, name)) if False else readable.get(name, name)
        return re.sub(r"\s+", " ", pretty)[:110]

    print("The areas the review names, by uncovered lines")
    print(f"{'area':<16}{'file':<46}{'lines':>6}{'uncovered':>10}{'covered':>9}")
    for area, rule in AREAS.items():
        members = [(n, f) for n, f in files.items() if re.search(rule["files"], n)]
        total_a = sum(f["lines"] for _, f in members)
        cov_a = sum(f["covered"] for _, f in members)
        print(f"{area:<16}{'(' + str(len(members)) + ' files)':<46}{total_a:>6}{total_a - cov_a:>10}{percent(cov_a, total_a):>9}")
        for name, f in sorted(members, key=lambda m: m[1]["covered"] - m[1]["lines"]):
            print(f"{'':<16}{name:<46}{f['lines']:>6}{f['lines'] - f['covered']:>10}{percent(f['covered'], f['lines']):>9}")
        if rule["functions"]:
            hits = []
            for file_name, names in uncalled.items():
                for n in names:
                    shown = short(n)
                    if re.search(rule["functions"], shown, re.I) or any(re.search(rule["files"], file_name) for _ in [0]):
                        if re.search(rule["functions"], shown, re.I):
                            hits.append((file_name, shown))
            if hits:
                print(f"{'':<16}never called, named for {area} (any file): {len(hits)}")
                for file_name, shown in hits[:25]:
                    print(f"{'':<18}{file_name}: {shown}")
                if len(hits) > 25:
                    print(f"{'':<18}and {len(hits) - 25} more in the full export")
    print("\nEvery file, least covered first (files with 20 or more lines)")
    print(f"{'file':<60}{'lines':>6}{'uncovered':>10}{'covered':>9}")
    for name, f in sorted(files.items(), key=lambda kv: (kv[1]["covered"] / kv[1]["lines"]) if kv[1]["lines"] else 1):
        if f["lines"] >= 20:
            print(f"{name:<60}{f['lines']:>6}{f['lines'] - f['covered']:>10}{percent(f['covered'], f['lines']):>9}")
    return 0


# -------------------------------------------------------------- allowlist ----
def allow_rules(path):
    """(where, rule, after the timing lane comment) for each rule in the file."""
    out, in_timing = [], False
    for raw in open(path):
        if raw.lstrip().startswith("#"):
            if "timing lane" in raw.lower():
                in_timing = True
            continue
        parts = raw.split("#")[0].split()
        if len(parts) == 2:
            out.append((parts[0], parts[1], in_timing))
    return out


def timing(path):
    for where, rule, after in allow_rules(path):
        if where == "ci" and after:
            print(rule)
    return 0


def any_rules(path):
    for where, rule, _ in allow_rules(path):
        if where == "any":
            print(rule)
    return 0


def pin(path, name):
    text = open(path).read()
    m = re.search(r"static let " + re.escape(name) + r" = EditorManifest\(\s*repo: \"([^\"]+)\", revision: \"([0-9a-f]+)\"", text)
    if not m:
        return 1
    print(m.group(1), m.group(2))
    return 0


def names(path):
    sys.path.insert(0, os.path.dirname(path))
    import corpus_src
    print("\n".join(corpus_src.USER_NAMES))
    return 0


# ---------------------------------------------------------------- summary ----
def read_status(folder, lane):
    path = os.path.join(folder, f"{lane}.status")
    if not os.path.exists(path):
        return None
    parts = open(path).read().rstrip("\n").split("\t")
    parts += [""] * (3 - len(parts))
    return dict(state=parts[0], seconds=parts[1], note=parts[2])


def read_results(folder, lane):
    path = os.path.join(folder, f"{lane}.results.tsv")
    if not os.path.exists(path):
        return None
    out = OrderedDict()
    for line in open(path):
        parts = line.rstrip("\n").split("\t")
        if parts and parts[0]:
            parts += [""] * (3 - len(parts))
            out[parts[0]] = (parts[1], parts[2])
    return out


def failing_since(reports, today, lane, name):
    """The date of the oldest consecutive earlier run of the lane that this
    name failed in, or None when the run before it did not fail it."""
    since = None
    earlier = sorted((d for d in os.listdir(reports) if re.fullmatch(r"\d{4}-\d{2}-\d{2}", d) and d < today), reverse=True)
    for day in earlier:
        results = read_results(os.path.join(reports, day), lane)
        if results is None:
            continue
        verdict = results.get(name, ("absent", ""))[0]
        if verdict == "fail":
            since = day
        elif verdict == "not run":
            continue
        else:
            break
    return since


def summary(reports, today):
    folder = os.path.join(reports, today)
    lines, failed_any = [], False
    guard = []
    for lane in LANES:
        status = read_status(folder, lane)
        if status is None:
            lines.append(f"  {lane:<9} not run today")
            continue
        results = read_results(folder, lane) or OrderedDict()
        counts = {k: sum(1 for v in results.values() if v[0] == k) for k in ("pass", "fail", "not run")}
        mark = {"ok": "ok    ", "failed": "FAILED", "not run": "not run"}.get(status["state"], status["state"])
        seconds = f" in {status['seconds']} s" if status["seconds"] else ""
        lines.append(f"  {lane:<9} {mark}{seconds}  {status['note']}".rstrip())
        if lane == "live":
            lines.append(f"            {counts['pass']} passed, {counts['fail']} failed, {counts['not run']} not run")
        if status["state"] == "failed":
            failed_any = True
        for name, (verdict, note) in results.items():
            if verdict == "fail":
                since = failing_since(reports, today, lane, name)
                if since:
                    guard.append(f"  failing since {since}: {lane}: {name}: fix or delete")
            elif verdict == "not run" and lane == "live":
                lines.append(f"            not run: {name}: {note}"[:200])
    out = [f"Desk lanes, {today}", ""] + lines
    if guard:
        out += ["", "Failing run after run:"] + guard
    out += ["", f"Reports: {folder}"]
    print("\n".join(out))
    return 1 if failed_any else 0


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 64
    command, args = sys.argv[1], sys.argv[2:]
    if command == "races" and args:
        return races(args)
    if command == "tests" and args:
        return tests(args)
    if command == "coverage" and len(args) == 3 and args[1] == "--root":
        return coverage(args[0], args[2])
    if command == "timing" and len(args) == 1:
        return timing(args[0])
    if command == "any" and len(args) == 1:
        return any_rules(args[0])
    if command == "pin" and len(args) == 2:
        return pin(*args)
    if command == "names" and len(args) == 1:
        return names(args[0])
    if command == "summary" and len(args) == 2:
        return summary(args[0], args[1])
    print(__doc__)
    return 64


if __name__ == "__main__":
    sys.exit(main())
