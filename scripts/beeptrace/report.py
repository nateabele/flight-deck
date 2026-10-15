#!/usr/bin/env python3
"""Tallies a beeps.log written by libBeepTrace (FD_TRACE_BEEPS=1) by test and by call site.

    report.py <beeps.log>

A beep made in a process with XCTest names its own test case. A beep made in the app under test
does not (no XCTest there), so it is given the test case the runner had open at that moment,
from the CASE lines both processes stamp on the same clock. Exit status 0 either way: this is a
report, not a gate. The last line is `BEEPS: <n>`.
"""
import collections
import re
import shutil
import subprocess
import sys


def main():
    cases = []  # (start, end, name), clock strings HH:MM:SS.mmm sort as text
    open_cases = {}
    beeps = []  # (stamp, proc, via, test, site)
    loads = 0
    lines = open(sys.argv[1], errors="replace").read().splitlines()
    i = 0
    while i < len(lines):
        line = lines[i]
        i += 1
        if line.startswith("LOAD "):
            loads += 1
        elif line.startswith("CASE "):
            _, t, pid, kind, name = line.split(" ", 4)
            if kind == "start":
                open_cases[(pid, name)] = t
            elif (pid, name) in open_cases:
                cases.append((open_cases.pop((pid, name)), t, name))
        elif line.startswith("BEEP "):
            m = re.match(r"BEEP (\S+) pid=\d+ proc=(.*) via=(\S+) test=(.*)$", line)
            stamp, proc, via, test = m.groups()
            frames = []
            while i < len(lines) and lines[i].strip():
                frames.append(re.sub(r"^\d+\s+\S+\s+0x[0-9a-f]+\s+", "", lines[i]).split(" + ")[0])
                i += 1
            # The call site: the first frame above the AppKit beep plumbing.
            site = next((f for f in frames if "NSBeep" not in f and "forwardMethod" not in f), "?")
            after = frames[frames.index(site) if site in frames else 0:]
            beeps.append((stamp, proc, via, test, " < ".join(after[:3])))

    tally = collections.Counter()
    for stamp, proc, via, test, site in beeps:
        if test.startswith("(no test"):
            test = next((n for s, e, n in cases if s <= stamp <= e), test)
        tally[(test, proc, site)] += 1
    rows = "\n".join(f"{n:5}  {test}  [{proc}]  {site}" for (test, proc, site), n in tally.most_common())
    if rows and shutil.which("xcrun"):
        rows = subprocess.run(["xcrun", "swift-demangle", "--simplified"], input=rows, capture_output=True, text=True).stdout or rows
    if rows:
        print(rows.rstrip())
    print(f"({loads} traced processes)")
    print(f"BEEPS: {len(beeps)}")


main()
