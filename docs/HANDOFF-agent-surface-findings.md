# Handoff — what Flight Deck can and cannot observe about a claude session

Findings from 2026-09-23/24, written for the Harness workstream. Companion to
`docs/superpowers/specs/2026-09-19-hook-fed-composer-state-design.md` (merged, `bdb6e8f`)
and `docs/HANDOFF-phone-answering.md`.

Everything below is **measured unless labelled otherwise**. Version-pinned claims say which
version, because this file exists largely to show how fast they expire.

---

## 1. The transcript is not a contract — claude 2.1.281 moved a write

**Through 2.1.280**, a blocking `AskUserQuestion` `tool_use` was appended when the dialog was
**raised**. **In 2.1.281 it is appended only at RESOLVE**, on the same beat as its
`tool_result`. A cancelled dialog produces no record at all.

Measured — three diagnostic pty runs:

```
t+54s  questions=no
t+56s  questions=no
t+59s  questions=no
t+61s  questions=YES     <- together with the submit
```

Corpus sweep, 178 records: orphan `use`/`result=None` pairs exist under 2.1.280 and nowhere
under 2.1.281. An August capture has the `tool_use` 8.4 s ahead of its result.

**Production consequence.** Flight Deck builds `OpenPrompt`/`PromptQuestion` from that
record, so under 2.1.281 it cannot observe an *open* question — the phone never renders the
card. Corroborated: `~/Library/Logs/flight-deck-prompt.log` has no `kind=question` after
2026-09-23T22:09 while `kind=permission` continues through 2026-09-24T08:02.
`~/.local/bin/claude` flipped to 2.1.281 on 2026-09-23 16:47; long-running sessions kept
their old binary, which is why questions worked that evening and stopped as sessions
restarted.

**Not fully proven:** no FD session was *confirmed* running 2.1.281 during the log gap. One
live 2.1.281 tab settles it.

Memory `blocking-tool-use-written-at-raise` has been corrected — permissions still write at
raise, `AskUserQuestion` no longer does.

---

## 2. Hooks carry the read side — `PreToolUse` fires for `AskUserQuestion`, with the payload

**This is the finding that matters most.** Measured on 2.1.281, against the **shipped**
plugin unmodified (`Resources/ClaudePlugin`, `--plugin-dir`, `FLIGHT_DECK_EVENT_DIR`), read
**while the dialog was still rendered**:

```
SessionStart
UserPromptSubmit
PreToolUse tool_name=AskUserQuestion

tool_input: {
  "questions": [{
    "question": "Which colour do you prefer?",
    "header": "Colour",
    "options": [
      {"label": "Crimson",  "description": "A deep, rich red…"},
      {"label": "Viridian", "description": "A cool blue-green…"},
      {"label": "Cobalt",   "description": "A vivid, saturated blue…"}
    ],
    "multiSelect": false
  }]
}
```

Everything the read path needs, structured, at raise time. Note `multiSelect` in particular:
`AnswerPlan` needs exactly that flag to choose checkbox-vs-single-select and currently
recovers it by inference.

**This dissolves two bug classes**, not two bugs: the 2.1.281 breakage above, and the
screen-parsing class in §3 — options arrive as JSON and are never recovered from rendered
text again.

**It does not touch the write side.** Answering is still typed keystrokes into the pty.

Throwaway probe: `scratchpad/pretooluse_probe.py` (prints event order, full payload, verdict).

---

## 3. The screen is not a contract either — a *description* can kill the parse

Live bug, 2026-09-23. An `AskUserQuestion` option description contained *"…on top of Level
0. I'd spin up a fresh worktree…"*, and the terminal wrapped immediately after "Level", so a
**description** line began `0. ` at column 5:

```
79  indent=0  |❯ 1. Level 1: Observe|
81  indent=5  |     0. I'd spin up a fresh worktree and start with brainstorming → |
82  indent=2  |  2. Validate Level 0 first|
```

`ChoiceDialog.list()` read line 81 as row number 0 → contiguity run broke → every later row
reset it → `lists.last(where: { $0.count >= 2 })` nil → `focusedRow` nil → **every phone
answer refused, deterministically**. Any option description that wraps onto a line beginning
`<digits>. ` does this.

Fixed by removing the parse from the drive path (§5), but §2 is what retires the class.

---

## 4. Injection: under kitty, `sendControl`'s explicit byte is DISCARDED

Confirms the Harness hypothesis, and **falsifies a load-bearing comment in our own code**.

`TextInjecting.sendControl` passes the control byte explicitly:

```swift
surfaceModel.sendKeyEvent(.init(key: key, action: .press, text: byte, mods: .ctrl))
```

and its doc (`TextInjecting.swift:117`) claims: *"The encoded byte is passed as `text` rather
than left to the key encoder to derive from key+modifier: it is what the terminal must
actually receive."*

**That is true under the legacy encoder and false under kitty** — which is the mode claude
enables. Traced through `vendor/ghostty/src/input/key_encode.zig` for `Ctrl+U`:

1. `.u` is not a functional key, so the entry comes from `unshifted_codepoint` →
   `{code: 117, final: 'u'}`. **Entry found.**
2. The utf8 short-circuit (`:157`) fires only for `.enter` / `.backspace`. Not `.u`.
3. The `plain_text` branch requires `binding_mods.empty()`; ctrl is set → **skipped**.
4. The `entry_ orelse` fallback that would `writeAll(event.utf8)` is **not reached**, because
   an entry exists.
5. Falls through to `KittySequence` → emits **`ESC[117;5u`**. Ctrl-E likewise `ESC[101;5u`.

**Candidate root cause for the live rename bug** (a rename into a composer *holding a draft*
submits the draft): if `Ctrl-U` leaves as `ESC[117;5u` and claude's composer does not act on
that form, the box never clears, the injected text appends to the draft, and the submit sends
both.

**Open, one pty probe away:** does claude's composer act on `ESC[117;5u`? Testable without a
GUI — put a draft in the composer, send those bytes, look; test both forms so the result is
self-diagnosing. Note a raw pty may leave claude in legacy mode, so the probe must detect
which mode is active rather than assume.

---

## 5. What shipped in the answer drive, and what it costs

`9b4f701..adc415d` (master, suite 2862/0 verified against the committed tree in isolation).
The per-step screen interlock was reduced from three checks to one cheap
`hasNumberedRowAtMarker`. `AnswerPlan` already computed every keystroke in advance; the parse
was verification, never computation.

Two consequences, both established by review **after** the design was approved:

- **A cursor not where the plan assumes now produces a WRONG ANSWER, not a refusal.**
  `AnswerPlan.plan` appends `.submit` unconditionally, so the review screen bounds a drive
  that *stops*, not one that *continues wrong*. Pinned by
  `AnswerDiagnosticsTests.testACursorSomewhereElseCommitsTheWrongAnswer`.
- **multiSelect is strictly worse than single-select, not better.** Verified in
  `AnswerPlan.plan`'s control flow: `cursor` carries from each toggle step into the next and
  into the `.action` step within one question (`cursor = option`), while every single-select
  step is `from: 0`. One bad landing cascades through that question's remaining steps, and
  the `.action` press it heads for is a committing `Next`/`Submit`, not a toggle.

A `focusedRow == 0` check on the **first step only** would close both while keeping the
design's intent (no per-step parse, no label matching). Offered three times, not taken up,
not added unilaterally.

**The livefuzz gate is unspent, not failed** — all runs aborted on the harness's
environmental abort (`stale/absent transcript: no AskUserQuestion record`) upstream of the
first keystroke, because of §1. Re-run it in full once §1 is resolved.

---

## 6. Operational hazards worth inheriting

- **The folder-trust prompt opens on `❯ No, exit`.** A rig that blindly sends Return to
  dismiss dialogs **quits its own session** and looks like a hang. Cost two sessions a run
  independently.
- **`git commit -- <explicit paths>` does not protect you from another session's index.**
  Staging is global. A path-scoped commit will still sweep a peer's staged work.
- **A plumbing commit leaves the real index holding pre-commit blobs** — a staged *reverse*
  of your own commit that a peer's `git commit` would silently apply. Re-point the real index
  afterwards (`git update-index --cacheinfo`), and verify.
- **Swapping `/Applications` invalidates UI-test authorization.** XCUITest resolves by bundle
  id, the already-running installed instance wins, and it is neither test-instrumented nor
  covered by the grant. Expect to re-authorize after every swap.
- **A synthetic-input probe on a machine a human is using can record the human as data.**
  `activate(ignoringOtherApps:)` loses to active typing, so a run can silently fail to become
  key. Assert your preconditions (`rowResolved`, `isKey`) **in the same output you report**.

---

## 7. The methodological lesson, stated because it recurred

Across ~6 review rounds, **every** overclaim was the *reassuring half* of a sentence going
unchecked:

- "`.onMove` is what turns on the tracking loop" — polluted by the machine's real user.
- "a never-key window delivers the up" — the press never landed on a row at all.
- "nothing is committed until the last step" — retracted correctly, then a false consolation
  attached: "multiSelect is the bounded case". It is the worse one.

The retraction was right every time; the comfort clause bolted onto it was wrong every time.
Three separate wrong conclusions came from probes asserting an outcome for a **configuration
they never established** — not from wrong numbers.

---

## 8. Where this leaves the architecture

The three-surface split proposed by Harness survives intact, with §2 promoting hooks well
past "is this session alive":

1. **Hooks** — session lifecycle *and* tool intent, including full `AskUserQuestion` payloads
   at raise. Merged and bundled.
2. **Proxy** — only for model-level detail hooks do not carry. Strong for its class; blind to
   client-side dialogs, claude's own UI, slash commands and the composer; and **observation,
   not control** — interactive stdin is the pty.
3. **Screen** — reduced to its irreducible minimum: is a client-side dialog covering the
   composer *right now*. Still the **only** thing that can answer it, because the dismissal
   edge (deny/Esc) does not exist in the event stream by construction.

Injection stays pty-typed regardless, which is where §4 bites.
