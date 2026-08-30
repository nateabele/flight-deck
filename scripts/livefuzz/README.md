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

## Reading the transcript: staleness, and telling environmental misses from real ones

The pty workspace (`capture-workspace/`) is reused run after run, so every run's own transcript
sits in `~/.claude/projects/.../*.jsonl` alongside every earlier run's. `newest_questions()` and
`newest_result()` have to pick out only the current run's record — and the naive way to do that,
filtering candidate **files** by mtime, is not sufficient: claude can flush and touch a
transcript file's mtime on shutdown well *after* the next run has already started, so an older
run's file can pass an `mtime >= since` test even though every record inside it predates `since`.
That let a genuinely stale record through and drove a live screen against a *previous* run's
option labels — producing a `row N does not read '<label>'` abort that read exactly like a real
interlock refusal, but meant nothing about the parser at all.

Correctness instead rests on each record's own `timestamp` field (ISO-8601, e.g.
`"2026-08-30T21:06:03.148Z"`), checked in `_newest_record()` against the run's own start time
(with a few seconds of slack for clock skew between this machine and claude's server — see
`CLOCK_SLACK`). File mtime is still used in `_transcript_files()`, but only as a cheap pre-filter
to limit how much needs scanning; it can never cause a stale record to be accepted, because it
cannot falsely *exclude* a genuine match (an append always bumps a file's mtime to at least the
record's own timestamp) — it can only over-admit candidates, which the per-record timestamp check
then filters correctly.

When no record at or after the run's own start turns up within the polling window, `drive()`
aborts with **`stale/absent transcript: no <kind> record after <run start>`** — a distinct,
unmistakable shape that can never be confused with a `step N (...): row X does not read
'<label>'` interlock refusal. Concretely, in `runfuzz.py` output:

- `abort=stale/absent transcript: no AskUserQuestion record after ...` — **environmental**,
  before the dialog is even driven. The current run's own `tool_use` never showed up in the
  transcript within the poll window (observed lag runs from well under a second to 30s+;
  occasionally the window runs out entirely, especially on a loaded machine). This says nothing
  about the parser — it means the harness couldn't observe a fresh enough record to build a plan
  from. Retry, or widen the poll window in `drive()`, before drawing any conclusion from it.
- `abort=stale/absent transcript: no tool_result record after ...` — the same kind of
  **environmental** miss, but on the other end: every interlock step passed and Return went to
  `("submit",)`, yet no confirming `tool_result` turned up either (same timestamp guard, applied
  in `newest_result()`, since a stale *answer* would be worse than a stale question — it would
  report a submission that never happened).
- `abort=step N ('option'|'action'|'submit', ...): row X does not read '<label>'` (or `expected
  focus`/`expected to land on`) — **real.** The interlock was checking a genuinely fresh record
  for THIS run and the screen did not read what the plan expected at that step. This is a finding
  about `ChoiceDialog.swift`, not about the harness's plumbing.

## Honest limit

The harness shares the real parser (`ChoiceDialog.swift`, via `probe.swift`), but its step loop
is still Python — it does not exercise `SessionStore`'s async settle behaviour (`perform`'s
recursive, repaint-then-check structure). A pass here means the interlock's *rules* held over a
live screen; it is not a substitute for driving `SessionStore` itself.
