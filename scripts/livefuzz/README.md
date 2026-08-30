# `scripts/livefuzz/` — the real answer-drive parser, fuzzed against a live claude

## Why this exists

Flight Deck answers a claude `AskUserQuestion` dialog by computing a keystroke program
(`AnswerPlan`, `Sources/FleetKit/AnswerPlan.swift`) and executing it while checking each step
against the screen through the interlock in `Sources/FlightDeck/ChoiceDialog.swift`. The Swift
test suite exercises `AnswerPlan`'s arithmetic and `ChoiceDialog` against **static** captured
screens — text files that never change in response to a keypress. Neither can observe a
submission, so neither can fail the way the real drive fails: a static-fixture suite stayed
green while a form containing a checkbox question drove part-way and stopped (see
`docs/HANDOFF-phone-answering.md`).

This harness drives a real `claude` TUI in a pty, and every check it makes is a call into the
**actual** `ChoiceDialog.swift`, via `probe.swift`, compiled together with it — not a
reimplementation. A `FAIL` here means what a refusal means in production: the interlock
declined a step because the screen did not read what the plan expected.

## What's here

- **`probe.swift`** — a tiny `@main` CLI wrapping `ChoiceDialog.focusedRow` and `ChoiceDialog.row`.
  Reads the screen on stdin, takes the operation on argv:
  - `probe focused` → the focused row, or `-1`
  - `probe reads <N> <label…>` → `true`/`false` for `ChoiceDialog.row(N, reads: …)`

  `fuzz.py` compiles it against `Sources/FlightDeck/ChoiceDialog.swift` on demand (see
  `build_probe()`), so a run always checks the current, real parser.

- **`fuzz.py`** — `plan()` mirrors `AnswerPlan.plan` (Swift) to build a list of steps, not
  keystrokes; `drive()` walks them one at a time, applying the same interlock as
  `SessionStore.perform`: confirm the cursor is on `step.frm`, confirm `step.to` reads the
  expected label, move, confirm it landed, only then press Return. Option wording is read back
  from the live transcript (`newest_questions()`) after the dialog appears — claude invents it,
  so neither this harness nor production can know it up front.

- **`runfuzz.py`** — scenarios (`single-set`, `checkbox-alone`, `mixed-set`), each driven `N`
  times with randomised answers. Prints one line per run: pass/fail, the abort reason (which
  step, expected vs. actual) when the interlock refused, and the tail of the transcript result.

## Running it

Needs a **live `claude` on the PATH**, burns real API quota, and takes roughly **70 seconds per
run**. Make the venv once (kept out of the repo — do not commit it, and do not put it under
`scripts/livefuzz/`):

```sh
python3 -m venv /tmp/livefuzz-venv && /tmp/livefuzz-venv/bin/pip install pyte
```

Then, from this directory:

```sh
cd scripts/livefuzz
/tmp/livefuzz-venv/bin/python runfuzz.py checkbox-alone 2   # any form with a checkbox question
/tmp/livefuzz-venv/bin/python runfuzz.py single-set 2       # no checkbox question — the control
/tmp/livefuzz-venv/bin/python runfuzz.py mixed-set 2        # checkbox + single-select together
```

## Honest limit

The harness shares the real parser (`ChoiceDialog.swift`, via `probe.swift`), but its step loop
is still Python — it does not exercise `SessionStore`'s async settle behaviour (`perform`'s
recursive, repaint-then-check structure). A pass here means the interlock's *rules* held over a
live screen; it is not a substitute for driving `SessionStore` itself.
