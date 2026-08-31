# Handoff — answering questions from the phone

**Branch:** `phone-question-checkbox` (unmerged; `master` untouched)
**Head:** this commit, on top of `5c86a21`
**Date:** 2026-08-30
**State:** checkbox forms now drive to submission against a live claude. One defect remains
undiagnosed, one is understood and unfixed, and neither deployed build has any of this.

Read this before touching the answer path. It is written so the next person does not
re-investigate what has already been ruled out — which means a claim in it that does not hold is
worse than no claim, so one is retracted below rather than quietly replaced.

## What was reported

1. A session says "Waiting for you" with no card under it, intermittently.
2. A prompt carrying several questions punted — the first shown read-only, the rest invisible,
   with "answer them on your Mac".
3. Later, from the phone: multi-question forms fill in **part-way** on the desktop and the Send
   button blocks forever.
4. Later still: **permission prompts show "Waiting for you" with no controls at all.**

## What is fixed and committed

| Commit | What |
|---|---|
| `95d0214` | Captures of the multi-question and checkbox dialogs (see below) |
| `0f248da` | `AnswerPlan` — the keystroke program, computed before any key is pressed |
| `15f77ec` | The driver: executes the plan, checking each step against the screen |
| `3055ca9` | The phone card collects a set and sends it as one command |
| `9a3a35d` | The card pages **one question at a time** |
| `4a97744` | `ChoiceDialog` strips a checkbox so the interlock can confirm the row |
| `d8e9695` | `scripts/livefuzz/` — a pty harness driving the **real** parser against a live claude |
| `3d28d77` | The interlock sees the unnumbered row a checkbox question submits through |
| `78b7ba5` | That row is decided one line late, so a wrapped label keeps its own row |
| `e22cb3f`, `eea1998` | The drive-level checkbox tests assert through the interlock instead of `.contains` |
| `c2f5d35`, `5c86a21` | Two defects in the **harness's own verdict** (see "The fuzz harness") |

Report 1 is fixed (`dae216f`, merged): the one-shot retry became a bounded, backing-off chase
whose condition is the card rather than a count. Report 2 is fixed (`2db6c52`, merged).
Report 3 is fixed at `3d28d77`/`78b7ba5`, described next. Reports 1 and 4 both had a second,
deeper cause — the open prompt's identity was never on the wire — addressed below; that one is
built on both sides and awaiting a live reproduction.

## The action row, as implemented (report 3)

A checkbox question submits through a row that reads `Submit` alone and `Next` inside a set, and
**the screen leaves it unnumbered** — it numbers `Type something` 5 and `Chat about this` 6,
straight past the row between them. `ChoiceDialog`'s rule that an unnumbered line is not a row
stays: claude echoes the user's own prompt with a marker and no number, and reading that as an
option reports a row nobody is on.

The exception is fenced by four conjuncts, each measured against the captures, each holding
something the others do not — `ChoiceDialog.actionRow` carries the reasoning per conjunct:

0. the run already holds **at least two** rows;
1. **every row already in the run carries a checkbox** — only a multiSelect screen has an action
   row, and on `question-single` the descriptions sit at the very column this rule looks at;
2. its text starts **at or past the run's own text column** — on a checkbox screen the option
   descriptions sit at **column 2** and the action row at **column 5**, which is what tells them
   apart on one screen; and
3. it is the **very next line** after the run's last row, which is what keeps the echoed prompt
   out: that line carries a marker and no number too, but it never sits one line under a row.

**And the row is admitted one line late.** A wrapped label satisfies all four at the moment it is
read, so a candidate is held until the next line says which it was: a line continuing the
numbering demotes it to a continuation, and so does a further indented line — two indented lines
under a row mean the first was a wrap, not the row a list ends on. Anything else confirms it — a
blank line, a rule, unindented text, a row that breaks the numbering, or the end of the viewport
— because nothing follows the action row inside a list. What protects that on a real screen is
the full-width rule claude draws under it — `Chat about this` is numbered **6** where the last
option is **5**, so without the rule line it would look like a continuation of the run and demote
a genuine `Submit`. A build that stopped drawing that rule takes the action row back out of
reach, which is a **refusal, not a wrong keypress**.

No `Submit`/`Next` literal exists in `ChoiceDialog.swift`. Those are claude's words;
`AnswerPlan.actionLabel` supplies them and `row(_:reads:)` checks them.

## What is NOT fixed — read this first

### A two-row numbered list in claude's own output outranks a live permission dialog

**Pre-existing.** Present before this branch and present after it.

`ChoiceDialog.list` takes the **last** qualifying run on screen — deliberately, so a scrollback
echo of an earlier dialog cannot beat the live one. But claude's own answer text routinely
contains numbered lists, and one drawn below a permission prompt becomes the last run.
`focusedRow` then returns `nil` and Allow-from-phone stops working for as long as that text is on
screen.

Verified against both parsers, on a screen that is `permission-bash.captured.txt` with two
ordinary numbered lines of claude prose appended:

```
$ swiftc -O Sources/FlightDeck/ChoiceDialog.swift scripts/livefuzz/probe.swift -o /tmp/probe
$ /tmp/probe focused < two-row-list-below-dialog.txt
-1              # identical at 945aeec, the parser this branch started from
$ /tmp/probe reads 0 Yes < two-row-list-below-dialog.txt
false
$ /tmp/probe focused < the-same-screen-with-one-such-line.txt
0               # one row is not a list, so a single line is harmless
```

The `run.count >= 2` guard added at `78b7ba5` closes only the *one*-row variant — a markdown
checklist line plus one indented line under it, which the action-row rule would otherwise have
grown into a two-row list. The failure survives at two genuine rows and always did.

It is undiagnosed-but-**understood**: the mechanism is known, the right fix is not, because "last
list wins" exists for a reason. Note the direction it fails in — `focusedRow` goes to `nil`, so it
fails to **refusal**, never to a keypress on a row nobody chose.

This is **not** a claim about report 4. That is a different symptom — a card rendering with no
controls at all, where this makes a drive refuse — and report 4's own cause is now known and
described below. Still worth ruling in or out; no more than that.

### Permission prompts (report 4) — the open prompt was never on the wire

Confirmed from the code and from a live failure: the phone showed *"Claude wants to run bash"*
for a dialog the Mac had long since moved past, Allow came back *"Your Mac has moved on from
this"*, and at that moment the Mac had **no** open prompt in any session. Not the retry race,
and not the `.toolCall` path being different from `.prompt`.

`ServerFrame` carried no prompt, by design — `OpenPrompt.find` derives it on both ends — so the
only signal a client got that anything had changed was the session's `activity`. One dialog
superseded by another **while the session stays `waiting`** therefore moved nothing at all: same
activity, often the same `waitingFor`, no event, and a card left describing a dialog that was
gone. `8b4fc56`'s lifecycle log records exactly that as `reason=superseded-by-…` with no `push`
beside it.

The fix puts the blocked call's `tool_use_id` — identity only, never the question — into
`WireSession.openPromptCall`, so a change of dialog is itself a wire change; `SessionStore
.commitStatuses` gains it as a third axis beside `backgroundWork`, and the phone re-derives on
it and draws nothing for a dialog the Mac does not name. See `OpenPromptIdentity` for the
three-state wire encoding and `PromptIdentityWireTests` for the tick nothing used to be sent
for. The `prompt_changed` refusal is untouched and stays the last line of defence: this changes
how often a stale answer is *sent*, not whether one is checked.

## Diagnostics — what to read before touching anything

Two logs, both unconditional and both in the Release build. Neither is behind
`FlightDeckAnswerTrigger`: that flag guards a control surface, these only observe.

| What | Unified log | File |
|---|---|---|
| Why an answer **drive** stopped, plus the whole screen it saw (`440d253`) | `category: answer`, error level | `~/Library/Logs/flight-deck-answer.log` |
| When a dialog **opens, closes and is answered**, and what left the Mac for it | `category: prompt`, default level | `~/Library/Logs/flight-deck-prompt.log` |

```bash
tail -f ~/Library/Logs/flight-deck-prompt.log
log show --last 30m --predicate 'subsystem == "dev.flightdeck.FlightDeck" && category == "prompt"' --style compact
log stream --predicate 'subsystem == "dev.flightdeck.FlightDeck" && (category == "prompt" || category == "answer")' --style compact
```

**The line to look for first is `answer`.** It carries the call the client tapped and the call
this Mac believes is open, side by side, which is what tells the stale-phone report apart from a
Mac that forgot:

```
prompt session=<uuid> answer sent=toolu_STALE open=toolu_OPEN code=prompt_changed   # the phone was behind
prompt session=<uuid> answer sent=toolu_STALE open=none      code=not_waiting       # the Mac had no dialog at all
prompt session=<uuid> answer sent=toolu_A     open=toolu_A   code=ok                # accepted
```

The other lines say what the Mac decided and what it sent. `push clients=N` is the one that
decides whose bug it is: a `closed` with a `push` behind it that reached a client is a phone
that failed to apply what it was sent; a `closed` with `clients=0`, or no `push` at all, is a
closure that never left the machine.

```
prompt session=… opened call=toolu_A agent=claude kind=question questions=2 options=3,4
prompt session=… opened call=toolu_B agent=claude kind=permission tool=Bash
prompt session=… unnamed code=prompt_changed         # "waiting", and this Mac cannot name the dialog
prompt session=… closed call=toolu_A reason=activity-idle
prompt session=… closed call=toolu_A reason=superseded-by-toolu_B   # never pushed: activity did not move
prompt session=… closed call=toolu_A reason=unnamed-prompt_changed  # answered at the keyboard, still waiting
prompt session=… push asserts=absent activity=idle clients=1
prompt session=- resume lastSeq=0 mode=snapshot-initial frames=1 waiting=1 clients=1
```

**No prompt is ever on the wire** — `OpenPrompt` is derived on both ends from a transcript each
already holds — so `activity` is the *whole* of what a client is told about a dialog. That is
why `superseded-by-…` has no push beside it, and it is the fact any repair has to start from.
Option labels and tool summaries go to the file only, never to the unified log.

## The fuzz harness

`scripts/livefuzz/` — committed, not a session scratchpad. Read its `README.md` for the harness
as it actually is; the short version is that it drives a **live claude in a real pty**, and every
check it makes is a call into the actual `Sources/FlightDeck/ChoiceDialog.swift`, compiled
together with `probe.swift`. A `FAIL` there means what a refusal means in production.

```
cd scripts/livefuzz
<venv>/bin/python runfuzz.py checkbox-alone 5   # any form with a checkbox question
<venv>/bin/python runfuzz.py mixed-set 5        # checkbox + single-select together
<venv>/bin/python runfuzz.py single-set 5       # no checkbox question — the control
```

Needs a live `claude` on the PATH, burns real quota, ~70 seconds a run.

### Retracted: the evidence this section used to cite

An earlier revision of this document quoted, as reproducing report 3 on the first run:

```
[mixed-set 1/20] FAIL answers=[[1, 3], [2]] err=None 71s result=''
```

**That `FAIL` was unconditional and proved nothing.** The pass condition ran through
`newest_result()`, which filtered raw JSONL transcript lines on the substring `AskUserQuestion`
*before* looking for a `tool_result` block — and a `tool_result` line names only the `tool_use_id`
it answers, never the tool. Checked against that session's own transcript directory: **1
`tool_result` line, 0 of them containing the string.** No run could pass, whatever happened on
screen. The `result=''` in the quoted line is the tell.

The bug it was pointing at is real and is fixed. It was not that line that showed it.

Two further defects in the harness's verdict were found and fixed this round:

- `c2f5d35` — the staleness guard filtered on **file mtime**, and claude bumps a transcript
  file's mtime on a later flush, so a run could read a *previous* run's questions and drive a live
  screen against stale labels. That produced a `row N does not read '<label>'` abort, which reads
  exactly like a genuine interlock refusal and meant nothing about the parser.
- `5c86a21` — the pass condition asserted that **an** answer was recorded, not that the **chosen**
  one was, so a drive that pressed the wrong row would have scored `OK`. That is the precise
  failure the interlock exists to prevent. Fixed by binding each run to its own transcript file
  and comparing the recorded labels against the driven indices.

Three separate defects in one harness's verdict, all of the same family: everything was tested
except the thing that decides pass or fail.

### What it reports now

Against the fixed parser and the fixed harness: **7 of 10 runs submitted** — `mixed-set` 3/5,
`checkbox-alone` 4/5 — with **zero interlock refusals**. All three misses aborted with the
harness's distinct `stale/absent transcript` reason. Each of the seven passes was also
cross-checked by hand against that run's own transcript file: the recorded answer matched the
chosen option index every time.

**Its limits, in order of how likely they are to bite:**

- **A miss is usually the machine, not the parser.** claude's on-disk transcript write can lag the
  on-screen TUI render by more than the harness's 45s poll window on a loaded machine, and the run
  is then scored a miss through no fault of the drive. `stale/absent transcript: …` is that
  outcome, and it is textually distinct from every real finding. Retry before concluding anything
  from it; the README lists all four abort shapes and which are real.
- **The step loop is still Python.** The harness shares the real parser, but not
  `SessionStore.perform`'s recursive, repaint-then-check structure, so it does not exercise the
  async settle behaviour. A pass means the interlock's *rules* held over a live screen.

## The captured grammar

**Twenty verbatim screen captures** in `Tests/FlightDeckTests/Fixtures/Claude/`, sha256-pinned and
version-stamped in `dialogs.captured.provenance.json`, in three batches: 2.1.241 (2026-08-23),
2.1.247 (`question-two*`, `question-single-247`) and 2.1.251 (the four checkbox screens). Three
have a paired `.jsonl` — the transcript record for the same session — so "the screen shows the
transcript's label" can be checked within one run. Made by driving a real claude in a pty and
rendering the byte stream through a terminal emulator, so they are what a terminal DISPLAYS — the
same thing `TextInjecting.readViewport` hands the driver.

| Shape | Enter does | Action row | Captured in |
|---|---|---|---|
| single-select | selects **and advances** | none; `Type something.` is the last row | `question-single`, `question-single-247`, `question-two*` |
| multiSelect alone | **toggles**, cursor stays | `Submit` at row n+1 | `question-multi`, `question-checkbox`, `-toggled`, `-submit-focused` |
| multiSelect in a set | toggles | **`Next`** at row n+1 | `question-set-with-checkbox` |

- **`question-multi.captured.txt` is a checkbox screen and draws `Submit` at line 20.** It has
  been in the fixtures since the first batch on 2026-08-23; the parser was written straight past
  it, and the test that was supposed to cover it asserted `.contains("Submit")` over the whole
  screen — which every checkbox capture satisfies from its tab strip (`←  ☐ Snacks  ✔ Submit  →`)
  alone, whether or not the row is reachable.
- Every screen opens with the cursor on **row 0** — including after an auto-advance. This is what
  makes the program deterministic; nothing carries a cursor across a screen boundary except
  between toggles inside one checkbox question.
- Rows are positional: `0…n-1` options, `n` "Type something", `n+1` the action row, `n+2` "Chat
  about this". The last two are drawn by the TUI and appear in **no** transcript.
- **The interlock's list stops at the action row.** `Chat about this` sits below the closing
  full-width rule, so `row(n+2, reads: "Chat about this")` is `false` on every checkbox capture —
  a run ends at that rule, and this is the same rule the deferral leans on.
- After the last question a **review** screen lists every answer and asks to submit. Nothing
  commits until then, which is why a mid-drive abort is safe.
- **The hint line is not a discriminator.** It gained `ctrl+g to edit in Cursor` between captures
  — it varies with installed tooling — and reads `Tab/Arrow keys to navigate` inside a set where a
  lone question reads `↑/↓ to navigate`. Use the checkbox glyphs and the tab strip.

## Ruled out, with evidence — do not re-investigate

- Report 1 was **not** body truncation (no real `AskUserQuestion` input approaches the 64 KB
  `maxItemBytes`; largest of 374 was 9.9 KB) and **not** a parse failure (0 of 374 fail).
- There is **no** structural way to answer `AskUserQuestion` from outside: no hook fires for it
  (`Permission required: No`, so `PermissionRequest` never sees it), the SDK's `canUseTool`
  never fires for it, and the free-text result shape is undocumented. Driving the TUI is the
  only mechanism, which is why the captures are load-bearing.
- 16% of real `AskUserQuestion` calls (62 of 374) carry more than one question, so the
  multi-question path is not an edge case.

## Build state

**Neither deployed build contains the action-row fix.** Both predate `3d28d77`.

- `/Applications/Flight Deck.app` was last swapped at **16:19:54 on 2026-08-29** — backup
  `~/Library/Application Support/Flight Deck/backups/20260829-161954`, and the bundle's binary
  still carries that mtime. That is earlier than `9a3a35d` (16:33), `4a97744` (19:42) and
  everything in this round. Swap with `scripts/swap-release.sh` before judging anything from a
  phone.
- Mobile3 last had `9a3a35d`'s Release installed (container `C85F43C1…`) on 2026-08-29 and has not
  been reinstalled since. Not re-verified while writing this: `xcrun devicectl device info
  processes --device Mobile3` reported the device unreachable. When it is reachable that command
  is the check — the container UUID identifies the build, and `devicectl install` does **not**
  replace the running process.
- Suites at `5c86a21`: **1971 macOS tests, 7 skipped, 0 failures** (1962 at `4a97744`; the
  difference is net-new coverage of the action row). The phone suite was **not** re-run this
  round — the last figure for it, 231, is from `4a97744` and is not current.
- Run the macOS suite with **`./scripts/test-unit.sh`**. Plain `xcodebuild test` cannot work
  headless here: `FlightDeckTests` is app-hosted, so it tries to launch `Flight Deck.app` and dies
  with `DVTAssertions: Assertion failed: childPID > 0` outside a GUI login session.

## What went wrong in the process, so it is not repeated

- **The tests were green while the feature was broken end to end.** They exercised a pure
  function's arithmetic and static captures that never change in response to a keypress. A
  drive test that cannot observe a submission cannot fail for the reason that matters.
- **A harness whose pass condition can never fire is not a harness.** Every run reported `FAIL`,
  which looked exactly like a reproduction, and the failure was read as a diagnosis. The check
  that would have caught it costs one run: a control case that is expected to PASS. Without one,
  "it failed" carries no information.
- **The driver was built on a parser that documented, in a comment, that it did not support the
  thing being asked of it** ("that box is deliberately *not* stripped"). Read the collaborator
  before extending it.
- **A deploy that says "installed" is not a deploy.** `devicectl install` replaces the bundle
  and leaves the old process running; the phone ran the previous build through a whole round of
  testing, and the giveaway was a string in the UI that this branch had deleted.
- **It was called shipped on unit tests alone**, before anything had run on hardware.
