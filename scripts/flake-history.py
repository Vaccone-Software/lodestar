#!/usr/bin/env python3
"""Which tests fail in CI, how often, and which of them are flaky: read from
the last N runs of ci.yml with `gh`, read-only (it never reruns, cancels or
writes anything). Standard library only. Run it as scripts/flake-history.sh.

  scripts/flake-history.sh [--runs 50] [--repo Vaccone-Software/lodestar]

Where it reads a run's tests from, best first:

  the results artifact   test-results-<attempt>, one JUnit file per run
                         (scripts/test.sh writes it, ci.yml uploads it for 30
                         days): every test, passes too.
  a green run            no artifact: a green run ran every test and all of
                         them passed or were allowed to skip, so any test is
                         known to have passed in it.
  a red run's log        no artifact: `gh run view --log-failed`, the tests
                         named by xctest's "error: -[Class test]" lines and
                         by test.sh's stall-limit and crashed-shard lines.
                         The red run says nothing of the tests it does not
                         name, which are not counted as seen in it.

Every attempt of a run is a run of its own (a re-run is how the same commit
fails and then passes).

A test is marked FLAKY when it failed and
  same sha    passed in another run of the same event on the same commit, or
  file same   passed in the next run on that branch after it, with the file
              the test lives in unchanged between the two commits.
The second is weaker than the first: it cannot see a fix made to the code
under test, only to the test's own file, so a bug fixed in a source file reads
as a flake. It is a candidate to look at, not a verdict; "same sha" is the
proof. A quarantine (Tests/quarantine.txt) is for the first kind.

Runs red for something other than a test are counted apart, by the step that
failed: the Metal toolchain download, the build, the cache, and so on.
"""
import argparse
import collections
import concurrent.futures
import datetime
import json
import os
import re
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET

GH = os.environ.get("GH", "gh")
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

ERROR = re.compile(r"(\S+\.swift):(\d+): error: -\[(\S+) (\S+)\] : ")
HANG = re.compile(r"✕ \S+ (?:has not moved in \d+s|still running after \d+s), in: Test Case '-\[(\S+) (\S+)\]' started")
DIED = re.compile(r"✕ \S+ ended before its last test: Test Case '-\[(\S+) (\S+)\]' started")
GATE = re.compile(r"✕ (?!tests failed)(.*)$")


def gh(*args):
    p = subprocess.run([GH, *args], capture_output=True, text=True)
    return p.returncode, p.stdout, p.stderr


def short(cls, test):
    """LodestarAppTests.SlabTests + testX -> SlabTests.testX"""
    return f"{cls.split('.', 1)[-1]}.{test}"


def parse_time(text):
    return datetime.datetime.fromisoformat(text.replace("Z", "+00:00"))


class Run:
    """One attempt of one run of ci.yml."""

    def __init__(self, id, attempt, sha, branch, event, created, conclusion):
        self.id, self.attempt, self.sha, self.branch = id, attempt, sha, branch
        self.event, self.created, self.conclusion = event, parse_time(created), conclusion
        self.source = None           # artifact | green | log | none
        self.failed = {}             # test -> (kind, file or None); kind: fail, hang, crash
        self.passed = set()          # tests known to have passed here (artifact)
        self.all_passed = False      # a green run without an artifact
        self.step = None             # the failing step of a red run
        self.cause = None            # tests | infra | gate | unknown

    def passes(self, test):
        return self.all_passed or test in self.passed


def list_runs(repo, limit):
    code, out, err = gh("run", "list", "-R", repo, "--workflow", "ci.yml", "--limit", str(limit), "--json",
                        "databaseId,conclusion,headSha,headBranch,event,startedAt,attempt,status")
    if code:
        sys.exit(f"gh run list failed: {err.strip()}")
    runs, skipped = [], 0
    for r in json.loads(out):
        if r["status"] != "completed" or r["conclusion"] not in ("success", "failure"):
            skipped += 1
            continue
        runs.append(Run(r["databaseId"], r["attempt"], r["headSha"], r["headBranch"], r["event"], r["startedAt"], r["conclusion"]))
        # A re-run replaces the run in the list; the attempts before it are
        # still there to be asked for.
        for k in range(1, r["attempt"]):
            code, out2, _ = gh("api", f"repos/{repo}/actions/runs/{r['databaseId']}/attempts/{k}")
            if code:
                continue
            a = json.loads(out2)
            if a.get("status") == "completed" and a.get("conclusion") in ("success", "failure"):
                runs.append(Run(r["databaseId"], k, a["head_sha"], a["head_branch"], a["event"],
                                a.get("run_started_at") or a["created_at"], a["conclusion"]))
            else:
                skipped += 1
    return runs, skipped


def from_artifact(repo, run):
    """The run's JUnit file, or False when it has none."""
    name = f"test-results-{run.attempt}"
    code, out, _ = gh("api", f"repos/{repo}/actions/runs/{run.id}/artifacts", "--jq",
                      f'.artifacts[] | select(.name == "{name}" and (.expired | not)) | .name')
    if code or name not in out.split():
        return False
    with tempfile.TemporaryDirectory() as tmp:
        code, _, _ = gh("run", "download", str(run.id), "-R", repo, "-n", name, "-D", tmp)
        path = os.path.join(tmp, "junit.xml")
        if code or not os.path.exists(path):
            return False
        return parse_junit(run, ET.parse(path).getroot())


def parse_junit(run, root):
    for case in root.iter("testcase"):
        test = short(case.get("classname"), case.get("name"))
        bad = case.find("failure")
        kind = "fail"
        if bad is None:
            bad = case.find("error")
            kind = "crash"
        if bad is not None:
            where = re.search(r"(Tests/[^:]+\.swift):\d+: ", bad.text or "")
            run.failed[test] = (kind, where.group(1) if where else None)
        elif case.find("skipped") is None:
            run.passed.add(test)
    run.source = "artifact"
    return True


def from_log(repo, run, keep_source=False):
    """A red run: which step failed, and the tests its log names."""
    args = ["-R", repo, "--attempt", str(run.attempt)]
    code, out, _ = gh("run", "view", str(run.id), *args, "--json", "jobs")
    steps = []
    if not code:
        for job in json.loads(out)["jobs"]:
            steps += [s["name"] for s in job["steps"] if s["conclusion"] == "failure"]
    run.step = steps[0] if steps else None
    code, log, _ = gh("run", "view", str(run.id), *args, "--log-failed")
    log = log if not code else ""
    hung, gate = {}, None
    for line in log.splitlines():
        m = ERROR.search(line)
        if m:
            file = re.search(r"(Tests/\S+\.swift)", m.group(1))
            run.failed.setdefault(short(m.group(3), m.group(4)), ("fail", file.group(1) if file else None))
            continue
        m = HANG.search(line)
        if m:
            hung[short(*m.groups())] = ("hang", None)
            continue
        m = DIED.search(line)
        if m:
            hung.setdefault(short(*m.groups()), ("crash", None))
            continue
        m = GATE.search(line)
        if m and gate is None:
            gate = m.group(1).strip()
    run.failed.update(hung)
    if not keep_source:
        run.source = "log" if log else "none"
    if run.step not in (None, "Test"):
        run.cause = f"infra: {run.step}" + (" (Metal)" if re.search(r"[Mm]etal", log) else "")
    elif run.failed:
        run.cause = "tests"
    elif "the tests do not build" in log:
        run.cause = "infra: the tests do not build" + (" (Metal)" if re.search(r"[Mm]etal", log) else "")
    elif gate:
        run.cause = f"gate: {gate[:70]}"
    else:
        run.cause = "unknown"


def read(repo, run):
    if from_artifact(repo, run):
        if run.conclusion == "failure":
            # The file names the tests that failed; a run red with none in it
            # (a step before the tests, or one of test.sh's own gates) is read
            # from its log for the reason.
            from_log(repo, run, keep_source=True)
    elif run.conclusion == "success":
        run.all_passed, run.source = True, "green"
    else:
        from_log(repo, run)


_changed = {}


def file_changed(repo, a, b, path):
    """Did `path` change between two commits? None when that cannot be told."""
    if a == b:
        return False
    if (a, b, path) in _changed:
        return _changed[(a, b, path)]
    verdict = None
    have = all(subprocess.run(["git", "-C", ROOT, "cat-file", "-e", f"{x}^{{commit}}"], capture_output=True).returncode == 0 for x in (a, b))
    if have:
        verdict = subprocess.run(["git", "-C", ROOT, "diff", "--quiet", a, b, "--", path], capture_output=True).returncode != 0
    else:
        code, out, _ = gh("api", f"repos/{repo}/compare/{a}...{b}", "--jq", "[.files[].filename]")
        if not code:
            try:
                verdict = path in json.loads(out)
            except ValueError:
                pass
    _changed[(a, b, path)] = verdict
    return verdict


def file_of(test, known):
    """Where a test lives: the file a failure named, else a file named for its class."""
    if known.get(test):
        return known[test]
    cls = test.split(".")[0]
    out = subprocess.run(["git", "-C", ROOT, "ls-files", f"Tests/*/{cls}.swift"], capture_output=True, text=True).stdout.split()
    return out[0] if out else None


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--runs", type=int, default=50, help="how many of ci.yml's latest runs to read (50)")
    parser.add_argument("--repo", default="Vaccone-Software/lodestar")
    args = parser.parse_args()

    runs, skipped = list_runs(args.repo, args.runs)
    with concurrent.futures.ThreadPoolExecutor(6) as pool:
        list(pool.map(lambda r: read(args.repo, r), runs))
    runs.sort(key=lambda r: r.created)

    # Where each failing test lives, from any run that named the file.
    files = {}
    for r in runs:
        for test, (_, file) in r.failed.items():
            if file and test not in files:
                files[test] = file

    table = collections.OrderedDict()
    for test in sorted({t for r in runs for t in r.failed}):
        seen = [r for r in runs if test in r.failed or r.passes(test)]
        fails = [r for r in runs if test in r.failed]
        flaky = None
        path = file_of(test, files)
        for f in fails:
            same = [g for g in runs if g is not f and g.sha == f.sha and g.event == f.event and g.passes(test)]
            if same:
                flaky = "same sha"
                break
            later = [g for g in runs if g.created > f.created and g.branch == f.branch]
            nxt = next((g for g in later if g.passes(test)), None)
            if nxt and path and file_changed(args.repo, f.sha, nxt.sha, path) is False:
                flaky = flaky or "file same"
        table[test] = dict(seen=len(seen), failed=len([f for f in fails if f.failed[test][0] == "fail"]),
                           hung=len([f for f in fails if f.failed[test][0] != "fail"]), flaky=flaky,
                           last=max(r.created for r in fails).date())

    red = [r for r in runs if r.conclusion == "failure"]
    red_tests = [r for r in red if r.cause == "tests"]
    only_flaky = [r for r in red_tests if all(table[t]["flaky"] for t in r.failed)]
    infra = collections.Counter(r.cause for r in red if r.cause and r.cause.startswith("infra"))
    other = collections.Counter(r.cause for r in red if r.cause and not r.cause.startswith(("infra", "tests")))
    sources = collections.Counter(r.source for r in runs)

    print(f"ci.yml, the latest {args.runs} runs of {args.repo}: {len(runs)} attempts read ({skipped} cancelled or unfinished left out)")
    print(f"  per-test data from: {sources['artifact']} results artifacts, {sources['green']} green runs (every test passed), "
          f"{sources['log']} red runs' logs, {sources['none']} red runs with no log left")
    print(f"  green: {len(runs) - len(red)}   red: {len(red)}")
    print(f"    red for tests: {len(red_tests)}  (of which every failing test is marked FLAKY: {len(only_flaky)})")
    print(f"    red for infrastructure: {sum(infra.values())}")
    for cause, n in infra.most_common():
        print(f"        {n:3}  {cause}")
    for cause, n in other.most_common():
        print(f"    red for something else: {n:3}  {cause}")
    print()
    if not table:
        print("no test failed in these runs")
        return 0
    width = max(len(t) for t in table)
    print(f"{'test':<{width}}  {'seen':>4}  {'failed':>6}  {'hung/died':>9}  {'last failed':<11}  flaky")
    for test, row in sorted(table.items(), key=lambda kv: (-kv[1]["failed"] - kv[1]["hung"], kv[0])):
        mark = f"FLAKY ({row['flaky']})" if row["flaky"] else ""
        print(f"{test:<{width}}  {row['seen']:>4}  {row['failed']:>6}  {row['hung']:>9}  {str(row['last']):<11}  {mark}".rstrip())
    return 0


if __name__ == "__main__":
    sys.exit(main())
