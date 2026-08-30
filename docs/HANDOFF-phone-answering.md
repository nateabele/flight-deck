# Handoff — answering questions from the phone

**Branch:** `phone-question-checkbox` (unmerged; `master` untouched)
**Date:** 2026-08-29
**State:** partly working, one known defect unfixed, one undiagnosed.

Read this before touching the answer path. It is written so the next person does not
re-investigate what has already been ruled out.

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

Report 1 is fixed (`dae216f`, merged): the one-shot retry became a bounded, backing-off chase
whose condition is the card rather than a count. Report 2 is fixed (`2db6c52`, merged).

## What is NOT fixed — read this first

### The unnumbered action row (cause of report 3)

A checkbox question submits through a row that reads `Submit` alone and `Next` inside a set.
**That row is unnumbered.** `ChoiceDialog`'s stated rule is that an unnumbered line is not a
row at all — deliberately, because claude echoes the user's own prompt with a marker and no
number, and reading that as an option reports a row nobody is on.

So `focusedRow` cannot report the action row and `row(_:reads:)` cannot confirm it, even though
arrow keys reach it. `AnswerPlan` aims at row `optionCount + 1` for it. Any form containing a
checkbox question therefore drives part-way and stops — exactly the reported symptom.

Fixing it means teaching `ChoiceDialog` to recognise that row **without** weakening the
unnumbered-line rule that protects against the prompt echo. It is the next task.

### Permission prompts (report 4) — undiagnosed

Not investigated. It is a different path — `.toolCall` → `OpenPrompt.permission`, not `.prompt`
— so it is **not** the same cause as reports 1–3, and it should not be assumed to be the retry
race either. Verify before changing anything.

## The fuzz harness

In this session's scratchpad (`/private/tmp/claude-501/…/scratchpad/`): `fuzz.py`,
`runfuzz.py`, `capture.py`, and a `capenv` venv with `pyte`.

```
./capenv/bin/python runfuzz.py mixed-set 20        # checkbox + single-select
./capenv/bin/python runfuzz.py checkbox-alone 20
./capenv/bin/python runfuzz.py single-set 20
```

It drives a **live claude in a real pty**, applies the exact keystroke program `AnswerPlan`
computes, and then reads the transcript back to check claude **recorded an answer**. Submission
is the pass condition — not that keystrokes were sent. A stalled drive leaves the tool rejected
and reads as `FAIL`.

It reproduced report 3 on the first run, in ~70 seconds, with no handset:

```
[mixed-set 1/20] FAIL answers=[[1, 3], [2]] err=None 71s result=''
```

**Its limit:** the plan is reimplemented in Python from `AnswerPlan.swift`, so it exercises the
grammar and the row arithmetic — where both known bugs live — but **not** `ChoiceDialog`'s
interlock, which is Swift. Wiring the real parser into a pty harness is the obvious next
improvement, and should have existed before any of this was called shipped.

## The captured grammar

Six verbatim captures in `Tests/FlightDeckTests/Fixtures/Claude/`, sha256-pinned and
version-stamped in `dialogs.captured.provenance.json`. Made by driving a real claude in a
136×34 pty and rendering the byte stream through a terminal emulator, so they are what a
terminal DISPLAYS — the same thing `TextInjecting.readViewport` hands the driver.

| Shape | Enter does | Action row |
|---|---|---|
| single-select | selects **and advances** | — |
| multiSelect | **toggles**, cursor stays | `Submit` at row n+1 |
| multiSelect in a set | toggles | **`Next`** at row n+1 |

- Every screen opens with the cursor on **row 0** — including after an auto-advance. This is
  what makes the program deterministic; nothing carries a cursor across a screen boundary
  except between toggles inside one checkbox question.
- Rows are positional: `0…n-1` options, `n` "Type something", `n+1` the action row, `n+2` "Chat
  about this". The last two are drawn by the TUI and appear in **no** transcript.
- After the last question a **review** screen lists every answer and asks to submit. Nothing
  commits until then, which is why a mid-drive abort is safe.
- **The hint line is not a discriminator.** It gained `ctrl+g to edit in Cursor` between
  captures — it varies with installed tooling. Use the checkbox glyphs and the tab strip.

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

- The Mac in `/Applications` is running **this branch**, swapped at 16:19 on 2026-08-29.
  Previous bundle: `~/Library/Application Support/Flight Deck/backups/20260829-161954`.
- Mobile3 is running this branch's Release (`9a3a35d`, container `C85F43C1…`). Verify with
  `xcrun devicectl device info processes --device Mobile3 | grep -i flightdeck` — the container
  UUID identifies the build, and an install does **not** replace the running process.
- Both suites green at `4a97744`: 1962 macOS, 231 phone.

## What went wrong in the process, so it is not repeated

- **The tests were green while the feature was broken end to end.** They exercised a pure
  function's arithmetic and static captures that never change in response to a keypress. A
  drive test that cannot observe a submission cannot fail for the reason that matters.
- **The driver was built on a parser that documented, in a comment, that it did not support the
  thing being asked of it** ("that box is deliberately *not* stripped"). Read the collaborator
  before extending it.
- **A deploy that says "installed" is not a deploy.** `devicectl install` replaces the bundle
  and leaves the old process running; the phone ran the previous build through a whole round of
  testing, and the giveaway was a string in the UI that this branch had deleted.
- **It was called shipped on unit tests alone**, before anything had run on hardware.
