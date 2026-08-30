#!/usr/bin/env python3
import json, random, sys, time
from fuzz import drive, newest_result

SCENARIOS = {
 "single-set": lambda r: dict(
    prompt=("Use the AskUserQuestion tool to ask me TWO questions in one call, both "
            "single-select: first, favourite language (Rust, Go, Swift); second, favourite "
            "editor (Vim, Emacs, Nano). One sentence per option. Do nothing else, just ask."),
    questions=[{"multi": False, "options": ["Rust","Go","Swift"]},
               {"multi": False, "options": ["Vim","Emacs","Nano"]}]),
 "checkbox-alone": lambda r: dict(
    prompt=("Use the AskUserQuestion tool with multiSelect true to ask which snacks I want. "
            "Exactly four options. One sentence each. Do nothing else, just ask."),
    questions=[{"multi": True, "options": ["a","b","c","d"]}]),
 "mixed-set": lambda r: dict(
    prompt=("Use the AskUserQuestion tool to ask TWO questions in one call: first, header "
            "Snacks, multiSelect TRUE, four snack options; second, header Seat, single-select, "
            "three seat options. One sentence each. Do nothing else, just ask."),
    questions=[{"multi": True, "options": ["a","b","c","d"]},
               {"multi": False, "options": ["x","y","z"]}]),
}

name = sys.argv[1]; runs = int(sys.argv[2])
rnd = random.Random(int(sys.argv[3]) if len(sys.argv) > 3 else 7)
ok = fail = 0
for i in range(runs):
    spec = SCENARIOS[name](rnd)
    answers = []
    for q in spec["questions"]:
        n = len(q["options"])
        answers.append(sorted(rnd.sample(range(n), rnd.randint(1, min(2, n)))) if q["multi"]
                       else [rnd.randrange(n)])
    t0 = time.time()
    final, abort = drive(spec["prompt"], answers)
    # `-2`: the workspace is reused run after run, so a stale transcript from an earlier run
    # always exists alongside this one's; a couple of seconds of slack absorbs clock rounding
    # without risking picking up that earlier run's result instead.
    result = newest_result(since=t0 - 2) if not abort else None
    submitted = bool(result) and "doesn't want to proceed" not in (result or "")
    status = "OK " if submitted else "FAIL"
    if submitted: ok += 1
    else: fail += 1
    print(f"[{name} {i+1}/{runs}] {status} answers={answers} abort={abort} "
          f"{time.time()-t0:.0f}s result={(result or '')[:90]!r}", flush=True)
print(f"== {name}: {ok} submitted, {fail} not ==", flush=True)
