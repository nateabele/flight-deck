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
  step, expected vs. actual, when the interlock refused; or an answer mismatch, when it did not
  but claude recorded the wrong options anyway), and the tail of the transcript result. The pass
  condition (`abort is None`) is entirely `drive()`'s: it already confirmed the recorded result
  both exists and names the options actually chosen before ever returning `abort=None` — this
  caller does not re-derive that.

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
`newest_result()` have to pick out only the current run's record. Two things that look sufficient
turned out not to be, in order:

1. **File mtime alone is not sufficient.** claude can flush and touch a transcript file's mtime
   on shutdown well *after* the next run has already started, so an older run's file can pass an
   `mtime >= since` test even though every record inside it predates `since`. That let a
   genuinely stale record through and drove a live screen against a *previous* run's option
   labels — producing a `row N does not read '<label>'` abort that read exactly like a real
   interlock refusal, but meant nothing about the parser at all.
2. **A pure cross-workspace `timestamp` comparison, on its own, is not sufficient either.** The
   fix for (1) was to check each record's own `timestamp` field against the run's start instead
   of file mtime — correct in principle, but the tolerance a real comparison needs for clock skew
   between this machine and claude's server (`CLOCK_SLACK`) turned out to be **wider than the
   real gap between two adjacent runs**: measured in this workspace, one run's final result can
   land as little as ~5 seconds before the next run even starts. A slack wide enough to absorb
   clock skew was therefore also wide enough to admit the *previous* run's genuine result as if
   it were this run's — a false **PASS**, which is worse than the false FAIL that (1) produced.

Correctness instead rests on **binding each run to its own transcript file**
(`_own_transcript_file()`): every run observed in this workspace starts a brand-new uuid
`.jsonl` and never reuses a previous run's file, so the file is identified by its OWN earliest
timestamped record (the first few lines — `last-prompt`, `mode`, `permission-mode` — carry no
`timestamp` at all; the first one that does anchors "when this session started"). Once bound,
`newest_questions()`/`newest_result()` read only that one file — a previous run's records live in
a file this call never even opens, so the ~5s race in (2) cannot arise, because there is nothing
to race with. The per-record `timestamp` check from (2) is kept as a second line of defence
*within* that one file, and as a documented, deliberately degraded fallback (see
`_newest_record()`'s `files=None` path) for the day a future claude reuses one file across runs —
at which point file-binding alone could no longer tell them apart and the *original* clock-skew
trade-off from (2) would return. File mtime is still used in `_transcript_files()`, but only ever
as a cheap pre-filter to limit how much needs scanning; it cannot falsely *exclude* a genuine
match (an append always bumps a file's mtime to at least the record's own timestamp), so it is
safe for narrowing candidates — it was never safe for accepting one, in either version of this
guard.

When no record at or after the run's own start turns up within the polling window, `drive()`
aborts with **`stale/absent transcript: no <kind> record after <run start>`** — a distinct,
unmistakable shape that can never be confused with a `step N (...): row X does not read
'<label>'` interlock refusal, or with the answer-mismatch abort below. Concretely, in
`runfuzz.py` output:

- `abort=stale/absent transcript: no AskUserQuestion record after ...` — **environmental**,
  before the dialog is even driven. The current run's own `tool_use` never showed up in its own
  transcript file within the poll window (observed lag runs from well under a second to 30s+;
  occasionally the window runs out entirely, especially on a loaded machine). This says nothing
  about the parser — it means the harness couldn't observe a fresh enough record to build a plan
  from. Retry, or widen the poll window in `drive()`, before drawing any conclusion from it.
- `abort=stale/absent transcript: no tool_result record after ...` — the same kind of
  **environmental** miss, but on the other end: every interlock step passed and Return went to
  `("submit",)`, yet no confirming `tool_result` turned up in this run's own file either.
- `abort=step N ('option'|'action'|'submit', ...): row X does not read '<label>'` (or `expected
  focus`/`expected to land on`) — **real.** The interlock was checking a genuinely fresh record
  for THIS run and the screen did not read what the plan expected at that step. This is a finding
  about `ChoiceDialog.swift`, not about the harness's plumbing.
- `abort=answer mismatch on question N (...): expected [...], recorded [...] (full result
  '...')` — also **real**, and the most serious kind: every interlock step passed, a fresh
  result was recorded, but it does not name the options the drive actually chose. This is the
  exact failure the interlock exists to prevent (pressing the wrong row) slipping past the
  interlock's own checks and only showing up in what claude recorded — "submission is the
  assertion" is not enough on its own; it has to be the **chosen** submission.

  This check compares TOKEN SETS, not substrings (see `answer_mismatch()` in `fuzz.py`): it
  parses each `"question"="answer"` pair out of claude's recorded text and splits the answer on
  `", "` into the individual labels claimed for that question, then compares that set against
  the labels actually chosen. A plain substring check (`label in result`) was tried first and
  found to have a one-directional false-PASS hole — if one option's label is a substring of
  another's (observed near-collisions in this workspace: `Popcorn`/`Salted popcorn`,
  `Chocolate`/`Dark chocolate`, `Cookies`/`Chocolate chip cookie`), pressing the WRONG one still
  contains-matches the shorter label, so a genuinely wrong answer could pass. Token-set
  comparison closes that, and additionally catches an extra, unchosen answer being recorded,
  which containment could never see either.

  Two things to know about this check:
  - `abort=could not parse recorded result into question/answer pairs: '...'` or
    `abort=recorded result names N question(s), expected M: '...'` — the result text did not
    parse into the expected `"question"="answer"` shape at all. This is its own distinct
    failure, never silently treated as either a match or a genuine mismatch.
  - **Known, deliberate limitation:** an option label that itself contains the literal substring
    `", "` will be split into two tokens by this check and reported as a mismatch that is not
    real. That is the safe direction on purpose — a false FAIL, loudly labelled with the full
    expected/recorded sets so it is easy to recognise — never a false PASS. No heuristic papers
    over this; if it ever fires, check whether an option's own label contains `", "` before
    treating it as a real finding about the drive.

## Honest limit

The harness shares the real parser (`ChoiceDialog.swift`, via `probe.swift`), but its step loop
is still Python — it does not exercise `SessionStore`'s async settle behaviour (`perform`'s
recursive, repaint-then-check structure). A pass here means the interlock's *rules* held over a
live screen; it is not a substitute for driving `SessionStore` itself.
