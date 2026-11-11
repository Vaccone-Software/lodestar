#!/usr/bin/env python3
"""What the system wrote down when a test shard died: the crash report macOS
keeps for the process, read and summarised so a failed CI run's log says
which thread, which call and which message ended it.

  scripts/crash-report.py --pid 4242 --since 1762553000 --keep shard.crash.ips

A process that dies on a signal (an abort, a trap, a bad access) leaves a
report named xctest-<date>.ips in DiagnosticReports, and the shard's own log
holds nothing of it: the app's log lines are on a buffered stdout, which an
abort does not flush, and what Swift or Foundation said when it died goes to
the system's log, not to the shard's stderr. The report names the exception,
the signal, the message the dying library left (`asi`), and every thread's
stack, and it is the only place any of that is.

The report is waited for (up to --wait seconds, none by default in a test):
the system writes it after the process has died and, on a busy runner,
takes seconds. Only a report for this pid, written since --since, is read.
Standard library only. Exit status: 0 when a report was found and printed, 1
when there was none.
"""
import argparse
import glob
import json
import os
import shutil
import sys
import time

DIRS = ["~/Library/Logs/DiagnosticReports", "/Library/Logs/DiagnosticReports"]


def find(pid, since, dirs):
    for directory in dirs:
        for path in sorted(glob.glob(os.path.join(os.path.expanduser(directory), "*.ips")), key=os.path.getmtime, reverse=True):
            try:
                if os.path.getmtime(path) < since:
                    continue
                body = parse(path)
            except (OSError, ValueError):
                continue
            if body.get("pid") == pid:
                return path, body
    return None, None


def parse(path):
    """An .ips file is two JSON documents: a header line, then the report."""
    with open(path, encoding="utf-8", errors="replace") as handle:
        text = handle.read()
    _, _, rest = text.partition("\n")
    try:
        body = json.loads(rest)
    except ValueError:
        body = json.loads(text)  # one document, from another macOS
    return body


def frame_line(frame, images):
    image = ""
    index = frame.get("imageIndex")
    if isinstance(index, int) and 0 <= index < len(images):
        image = images[index].get("name") or ""
    symbol = frame.get("symbol") or "?"
    where = ""
    if frame.get("sourceFile"):
        where = f" ({frame['sourceFile']}:{frame.get('sourceLine', '?')})"
    return f"    {image:<28} {symbol}{where}"


def summarise(path, body, frames):
    args_frames = frames
    out = []
    exception = body.get("exception") or {}
    termination = body.get("termination") or {}
    out.append(f"  crash report {path}")
    out.append("  exception: " + ", ".join(f"{k}={v}" for k, v in exception.items() if k in ("type", "signal", "subtype")))
    if termination:
        out.append("  termination: " + ", ".join(f"{k}={v}" for k, v in termination.items() if k in ("namespace", "indicator", "reasons")))
    for library, lines in (body.get("asi") or {}).items():
        for line in lines if isinstance(lines, list) else [lines]:
            out.append(f"  said by {library}: {str(line)[:300]}")
    images = body.get("usedImages") or []
    threads = body.get("threads") or []
    faulting = body.get("faultingThread")
    if isinstance(faulting, int) and 0 <= faulting < len(threads):
        thread = threads[faulting]
        label = thread.get("queue") or thread.get("name") or ""
        out.append(f"  crashed thread {faulting} {label}".rstrip())
        for frame in (thread.get("frames") or [])[:frames]:
            out.append(frame_line(frame, images))
    # The main thread in full when it is not the one that aborted: XCTest ends
    # a shard from a thread of its own when a wait on expectations sees main
    # stay in one call too long ("A stall was detected while waiting on
    # expectations"), and what main was in is then the whole answer.
    for number, thread in enumerate(threads):
        if number != faulting and thread.get("queue") == "com.apple.main-thread":
            out.append(f"  main thread {number}")
            for frame in (thread.get("frames") or [])[:args_frames]:
                out.append(frame_line(frame, images))
    # The other threads, one line each: what each was in, so a deadlock or a
    # thread caught mid-teardown shows beside the one that aborted.
    for number, thread in enumerate(threads):
        if number == faulting or thread.get("queue") == "com.apple.main-thread":
            continue
        top = [f.get("symbol") for f in (thread.get("frames") or [])[:3] if f.get("symbol")]
        label = thread.get("queue") or thread.get("name") or ""
        out.append(f"  thread {number} {label}: {' < '.join(top)}".rstrip())
    return out


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--pid", type=int, required=True)
    parser.add_argument("--since", type=float, default=0, help="only reports written at or after this epoch second")
    parser.add_argument("--wait", type=float, default=0, help="seconds to wait for the report to be written")
    parser.add_argument("--keep", help="copy the report here")
    parser.add_argument("--frames", type=int, default=25)
    parser.add_argument("--dirs", default=os.environ.get("CRASH_REPORT_DIRS", ":".join(DIRS)))
    args = parser.parse_args()
    dirs = [d for d in args.dirs.split(":") if d]
    deadline = time.time() + args.wait
    while True:
        path, body = find(args.pid, args.since, dirs)
        if path or time.time() >= deadline:
            break
        time.sleep(1)
    if not path:
        print(f"  no crash report for pid {args.pid} in {', '.join(dirs)}")
        return 1
    print("\n".join(summarise(path, body, args.frames)))
    if args.keep:
        shutil.copyfile(path, args.keep)
        print(f"  the report: {args.keep}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
