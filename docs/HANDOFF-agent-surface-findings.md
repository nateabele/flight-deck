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

## 4. Injection: `sendControl`'s explicit byte SURVIVES — but only by an unguarded invariant

**Corrected 2026-09-25.** This section previously claimed the opposite: that under kitty the
byte is discarded and ghostty emits `ESC[117;5u`. That was wrong, it was written into
`TextInjecting.sendControl`'s doc comment (106b357) on the strength of this section, and both
have been corrected. The error is recorded rather than deleted because it is the fourth instance
of this file's own §7 lesson — and this time the overclaim was in the correction.

`TextInjecting.sendControl` passes the control byte explicitly:

```swift
surfaceModel.sendKeyEvent(.init(key: key, action: .press, text: byte, mods: .ctrl))
```

**That byte is what the terminal receives, under kitty as well as legacy.** Every link traced in
source (static trace, no probe):

1. `Ghostty.Input.KeyEvent.init` defaults `unshiftedCodepoint` to `0`; `sendControl` never
   passes it, and **nothing in `Sources/` ever sets it.**
2. `withCValue` copies it to the C struct unchanged (`Ghostty.Input.swift:209`), and `text`
   becomes `keyEvent.text`. `sendKeyEvent` has exactly one definition — a trivial pass-through
   to `ghostty_surface_key` (`Ghostty.Surface.swift:60-64`).
3. `ghostty_surface_key` (`apprt/embedded.zig:1762`) converts via `event.keyEvent()`
   (`:1269`), which passes `unshifted_codepoint` straight through. **Note:** `embedded.zig`
   declares *two* unrelated `KeyEvent` structs with a same-named converter — `Surface.KeyEvent`'s
   `core()` at `:93`, reached only by `ghostty_app_key` and
   `ghostty_surface_key_is_binding`, and the extern `CAPI.KeyEvent`'s `keyEvent()` at `:1255`,
   which is the one `ghostty_surface_key` actually takes. Reading `core()` by name is how the
   original trace went wrong.
4. There is **no write to `unshifted_codepoint` anywhere on the macOS/embedded path.** The only
   real derivation in ghostty is `apprt/gtk/class/surface.zig:1406`.
5. `kitty.zig`'s `raw_entries` holds only functional, keypad and modifier keys — **no plain
   letters.** `.u` and `.e` never match it.
6. So the table lookup misses, and `key_encode.zig:132` synthesizes an entry only
   `if (event.unshifted_codepoint > 0)` — false here. `entry_` is `null`.
7. Nothing intercepts `.u`+ctrl in between: `composing` is false; the utf8 short-circuit
   (`:158`) is `.enter`/`.backspace`-only; the `report_all` and `plain_text` branches both
   require `binding_mods.empty()` and ctrl is set. (Even reaching `plain_text` changes nothing —
   `0x15` is a control character, so it breaks out to the same fallback.)
8. `key_encode.zig:217` — `entry_ orelse { if (event.utf8.len > 0) return try
   writer.writeAll(event.utf8); … }`. The byte goes out verbatim. `KittySequence` is constructed
   at `:228`, **after** that fallback, so it is unreachable with a null entry.

**The invariant, which is the part worth carrying:** the byte survives because Flight Deck never
supplies an unshifted codepoint — not because the encoder promises anything. A caller that does
supply one (the real `NSEvent` path derives it for a human keypress) makes `:132` yield an entry
and flips the same call to `ESC[117;5u`, discarding the byte. No test guards this, because
nothing under XCTest stands on a real surface.

**Consequences for what this file used to claim:**

- The "candidate root cause for the live rename bug" is **withdrawn.** A rename into a composer
  holding a draft does submit the draft, but not because Ctrl-U left as CSI-u — it does not.
  **That bug currently has no identified cause.**
- §7's raw-`\x04` pty-probe entry stands as a lesson, but its own reassuring clause ("ghostty
  actually encodes Ctrl+U as `ESC[117;5u`") was itself unchecked, and is now falsified for this
  call path.

**What is genuinely open, and it is not the old question.** Live test #3 left
`;5u;5u/rename Rename 3` at a zsh prompt — two CSI-u tails, matching Ctrl-E then Ctrl-U. The
trace above says this path cannot emit them, and `git log -S` shows `text: byte` entered in
6c2a39d and never changed, so the code under test did carry it. **Unexplained.** Asking "does
claude honour `ESC[117;5u`" is moot while nothing sends it; the question is what produced those
bytes. A probe must record **which keyboard mode was active and which code path sent the keys**,
and refuse a verdict without establishing both.

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

**Fourth instance, added 2026-09-25, and it is the sharpest one:** §4 of this file asserted that
ghostty discards `sendControl`'s explicit byte and emits `ESC[117;5u`. The retraction it rested
on was right — the old comment's phrasing *was* sloppy — but the replacement claim was false, and
it was written into production comments before anyone traced the call site's own
`unshifted_codepoint`. **A correction is not exempt from the rule it invokes.** When you overturn
a claim, the replacement needs the same evidence you demanded of the original.

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
