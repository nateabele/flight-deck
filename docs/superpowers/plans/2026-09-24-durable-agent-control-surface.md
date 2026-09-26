# A durable control surface for agent behaviour — Implementation Plan

## Context

Flight Deck reads agent state from surfaces that are not contracts. Two broke in one week
without announcement — a wrapped option *description* beginning `0. ` killed the select-list
parse and refused every phone answer; and Claude Code 2.1.281 moved the `AskUserQuestion`
`tool_use` record from dialog-*raise* to dialog-*resolve*, so the phone stopped rendering
question cards in production.

The goal is not to fix those two. It is to end the class: **a silent upstream change should
fail a test, not a user.**

## The finding that determines the plan

A drift detector already exists and is good — `scripts/adapterprobe` carries 42 per-claim cells
across both agents, diffs `baseline.json`, is tier-aware, and exits 1 on capability drift / 3 on
harness failure. It has a row for `openPromptReader`, the exact capability 2.1.281 broke.

**That row would have exited `0` through the regression.** `capabilities.py:265-273` feeds it a
frozen fixture — `question-single.captured.jsonl`, captured at claude **2.1.241** — which still
parses perfectly. The *codex* side of the same row is live-driven (`:277-370`): it forces a real
approval dialog and measures the rollout. The claude side never drives a live claude at all.

Three more gaps compound it:

- **`versions_changed` does not affect the exit code.** `run.py:175` computes it, `:628` prints
  it, `_exit_code` (`:474-489`) ignores it. A run against a brand-new binary with identical
  cells exits `0`. `corpus.json` staleness is likewise printed, never enforced.
- **Nothing runs it.** No CI (`.github/` absent), no git hooks, no other script calls it, and
  `test-adapters.sh` is in neither `AGENTS.md` nor `CONVENTIONS.md`. It runs when a human types it.
- **Default tier is `cheap`, which skips `openPromptReader` entirely.**

`baseline.json` records `claude 2.1.263`; installed is **2.1.281**. Eighteen versions of
undetected drift across exactly the window both bugs appeared in.

So the permanent solution is **mostly wiring and sharpening what exists** — far cheaper, and far
likelier to survive, than building a proxy.

## Approach

Three surfaces, each authoritative only for what it can genuinely see:

1. **Hooks** — lifecycle *and* tool intent. `PreToolUse` fires for `AskUserQuestion` while the
   dialog is open, carrying every question, option `label`/`description`, and `multiSelect`.
2. **Screen** — reduced to its irreducible minimum. The inventory states it cleanly: *every fact
   about **what** to answer is transcript-derived; every fact about **where the cursor is** is
   screen-derived.* The second cannot move — and the deny-fires-nothing asymmetry means the
   dismissal edge does not exist in any event stream, so the screen is permanently required.
3. **Proxy** — deferred behind a spike, not built. See below.

Plus the part that makes it durable: **drift becomes loud**.

## Tasks

### Task 1: Make `claude.openPromptReader` live-driven

**Files:** Modify `scripts/adapterprobe/capabilities.py` (`_open_prompt_reader`, claude arm at
`:212-221`; row registration in `ROWS`). **Test:** the row is its own test — verified by running
the matrix.

**Why first:** this row exists to guard the exact capability 2.1.281 broke, and it exited `0`
through the regression because the claude arm feeds it `_CLAUDE_OPEN_PROMPT_TAIL`
(`capabilities.py:61` → `question-single.captured.jsonl`, captured at claude **2.1.241**), which
still parses. Everything else in this plan is worth less than fixing this one row.

- [ ] **Step 1: Confirm the row currently passes against the stale fixture**

`scripts/test-adapters.sh --tier full --only claude.openPromptReader` (check the flag spelling
against `run.py`'s argument parser first). Record that it reports `ok`. That is the false
negative this task removes — capture it before changing anything.

- [ ] **Step 2: Replace the claude arm with a live drive**

Keep the `declared` read. Replace the fixture read with a real turn. Follow the shape
`_rename`'s claude arm already uses (`capabilities.py:555-585`) — that is the in-repo template
for driving a live claude, and it is correct:

```python
        declared = ctx.probe(["declare", "claude"])["openPromptReader"]
        cid = ctx.probe(["prepare", "claude", "--cwd", ctx.sandbox.root])["conversationID"]
        transcript = <the transcript path, derived the way _rename derives it>
        text = ctx.probe(["launch-command", "claude", "--id", cid,
                          "--cwd", ctx.sandbox.root])["text"]
        with ctx.pty("claude", [ctx.login_shell, "-lc", text]) as term:
            term.wait([_UP_MARKER["claude"]], 30)
            term.send(b"Use the AskUserQuestion tool to ask me which colour I prefer, "
                      b"with options Crimson, Viridian and Cobalt.\r")
            # The dialog must be ON SCREEN when the transcript is read — that is the whole
            # point. Establish it, do not assume it.
            raised = term.wait(["Which colour", "Esc to cancel"], 120)
            if not raised:
                return Observation(declared=declared, observed="error",
                                   detail="no AskUserQuestion dialog within 120s; the row "
                                          "cannot distinguish a broken reader from a model "
                                          "that never called the tool")
            tail = <read the live transcript's tail>
            out = ctx.probe(["open-prompt", "claude", "--activity", "waiting"], stdin=tail)
        return Observation(declared=declared, observed=out.get("kind") is not None,
                           detail=f"live dialog raised; reader returned {out.get('kind')!r}")
```

Fill the two bracketed pieces from how `_rename` does them — do not invent new helpers.

- [ ] **Step 3: Verify the row now catches the regression**

Re-run the same single-row command against the **installed** claude. On 2.1.281 the transcript
carries no `tool_use` while the dialog is open, so the reader returns `null` and the row must now
read **`broken`**, not `ok`.

**If it still reads `ok`, this task is wrong and must not be committed** — either the dialog was
not actually open when the tail was read, or the tail was read from the wrong place. Report that
rather than adjusting the assertion.

- [ ] **Step 4: Move the row's tier if needed, and say why**

A live drive cannot run in `cheap`. Confirm the row is `tier="full"` and that its comment states
the cost, matching how the codex arm already justifies being the deliberate exception.

- [ ] **Step 5: Commit**

```bash
git add scripts/adapterprobe/capabilities.py
git commit -m "Drive a live claude for openPromptReader instead of a 2.1.241 fixture"
```

---

### Task 2: Make version drift fail the run

**Files:** Modify `scripts/adapterprobe/run.py` (`_exit_code` at `:474-489`; `diff_baseline`'s
`versions_changed` at `:169-175`; `corpus_staleness` at `:187-191`). **Test:**
`scripts/adapterprobe/tests/test_runner.py`.

Today `versions_changed` and `corpus_staleness` are computed and **printed** (`:628-629`, `:588`)
and never reach `_exit_code`. A run against a brand-new agent build whose cells happen to be
unchanged exits `0` — which is exactly how a fixture-backed row keeps passing against a binary it
has never seen.

- [ ] **Step 1: Write the failing test**

Add to `tests/test_runner.py`, following its existing fake-context style:

```python
    def test_a_version_change_alone_is_not_a_clean_run(self):
        diff = {"changed": {}, "added": {}, "removed": {},
                "versions_changed": {"claude": ("2.1.263", "2.1.281")}}
        code, _ = run._exit_code(diff)
        self.assertNotEqual(code, 0,
            "a new agent build with identical cells must not report clean: the cells may be "
            "identical only because a frozen fixture cannot see the change")
```

- [ ] **Step 2: Run it and watch it fail**

`/tmp/adapterprobe-venv/bin/python -m unittest tests.test_runner -v` from
`scripts/adapterprobe`. Expect FAIL returning 0.

- [ ] **Step 3: Fold version drift into the exit code**

Give it its **own** code — do not reuse `1` (capability drift) or `3` (harness failure), because
a version bump with unchanged cells is a different thing from either and a caller should be able
to tell them apart. Document the new code in `_exit_code`'s docstring alongside the existing
ones, and keep the existing ranking intact: `error` still outranks plain drift.

- [ ] **Step 4: Run the suite**

`/tmp/adapterprobe-venv/bin/python -m unittest discover -s tests`. Expect the new test to pass.

**Known pre-existing failure, not yours:** `test_grammars.test_claude_strips_shell_metacharacters_codex_does_not`
fails because production deliberately removed claude's shell-metacharacter strip (see
`ClaudeAdapter.swift:48`, "the old shell-metacharacter strip"). It is stale and committed. Leave
it failing, and note it in your report — Task 4 decides its fate.

- [ ] **Step 5: Commit**

```bash
git add scripts/adapterprobe/run.py scripts/adapterprobe/tests/test_runner.py
git commit -m "Fail the matrix when the agent version moved, even if every cell agrees"
```

---

### Task 3: Wire the gate into something that runs

**Files:** Modify `AGENTS.md` (the Commands block), `scripts/adapterprobe/README.md`.

A gate nobody runs is not a gate. There is no CI (`.github/` does not exist), no git hooks, and
`test-adapters.sh` appears in neither `AGENTS.md` nor `docs/CONVENTIONS.md`.

- [ ] **Step 1: Add the cheap tier to the documented loop**

In `AGENTS.md`'s Commands block, beside `./scripts/test-unit.sh`, add `./scripts/test-adapters.sh`
with a one-line description saying it re-derives the adapter capability matrix against the live
agents and exits non-zero on drift. State that the default tier is `cheap` and spends no tokens.

- [ ] **Step 2: State the `full` cadence and its cost honestly**

`full` drives live agents and spends real tokens, so it must not be folded into `test-unit.sh`.
Document in `scripts/adapterprobe/README.md`: run `full` after any agent upgrade, and record the
version it was last run at. Point at `baseline.json`'s `versions` map as where that is already
recorded.

- [ ] **Step 3: Commit**

```bash
git add AGENTS.md scripts/adapterprobe/README.md
git commit -m "Put the capability matrix in the documented loop"
```

---

### Task 4: Promote load-bearing comment pins to checked rows

**Files:** Modify `scripts/adapterprobe/capabilities.py` (`ROWS` and new row functions).

~15 source comments carry version claims nothing checks. These are the next 2.1.281s. Highest
value first, because each is load-bearing for a decision:

| Claim | Where it is asserted today |
|---|---|
| Escape on a permission dialog is a real denial | `ClaudeDialogDriver.swift:32-34`, "measured against 2.1.241" |
| `AskUserQuestion` input shape (`questions/options/multiSelect`) | `OpenPrompt.swift:76-78`, "claude 2.1.241" |
| Codex paste-detects a same-burst Return | `CodexTextChannel.swift:142-144`, "0.153.4" |
| `queuedMessagesHint` wording | `ClaudeTextChannel.swift:36-39`, "verified 2.1.268" — **display-only**, so lowest priority |

- [ ] **Step 1: Add rows for the first three, cheapest first**

Follow the existing `kind="fact"` row pattern. Where a claim genuinely cannot be probed without a
live turn, mark it `tier="full"` and say so; where it cannot be probed at all, **change the source
comment to say it was never machine-checked** rather than leaving a version number that implies
it was.

- [ ] **Step 2: Decide the stale `test_grammars` assertion**

`test_claude_strips_shell_metacharacters_codex_does_not` asserts behaviour production removed
deliberately. Either update it to assert the *current* contract (metacharacters survive; control
characters do not — see `AgentAdapter.sanitizedTitle`'s doc) or delete it. Do not leave a
committed failing test.

- [ ] **Step 3: Run the suite and the cheap tier**

`/tmp/adapterprobe-venv/bin/python -m unittest discover -s tests`, then
`./scripts/test-adapters.sh` (cheap). Both must be clean.

- [ ] **Step 4: Commit**

```bash
git add scripts/adapterprobe/capabilities.py scripts/adapterprobe/tests
git commit -m "Check the version claims that were only ever comments"
```

---

### Task 5: Migrate the open-question read onto `PreToolUse`

**Files:** `Sources/FleetKit/OpenPrompt.swift`, `Sources/FlightDeck/Fleet/PromptService.swift`,
`Sources/FlightDeck/HookEventWatcher.swift` (read alongside, do not widen `ComposerReadiness`).
**Test:** `Tests/FlightDeckTests/`.

**This task is UNOWNED — see "Open coordination". Do not dispatch it without a decision.**

`OpenPrompt.find` (`OpenPrompt.swift:224-239`) requires an *unanswered* `tool_use` record while
`activity == waiting`. 2.1.281 writes that record only at resolve, so there is nothing to find
while the dialog is open. The same content arrives structurally via `PreToolUse` —
verified: `tool_input` carries every `question`, `header`, option `label`/`description`, and
`multiSelect`.

Design constraints that are not negotiable:

- **There is no dismissal edge.** A cancelled dialog fires no hook at all. Whatever holds
  open-question state needs its own expiry or reconciliation — it must not become a state that
  can never be cleared. That trap is why `.dialog` was removed from `ComposerReadiness`.
- **Do not widen `ComposerReadiness`.** It is deliberately two fields. Read the same
  `events.ndjson` with a parallel reader.
- **Claude only.** `CodexEventMapper.swift:31-35` records that codex writes nothing to its
  rollout while an approval list is up, so codex has no structured source for an open dialog.
  State that in the code rather than leaving it looking like an oversight.

---

### Task 6: Fix `sendControl`'s false comment

**Files:** `Sources/FlightDeck/TextInjecting.swift` (`sendControl` at `:122-127`, and the
`sendKillLine` doc at `:16-22`).

`sendControl` passes the control byte explicitly as `text:` and its doc asserts that byte "is
what the terminal must actually receive". **True under legacy, false under kitty.** Traced
through `vendor/ghostty/src/input/key_encode.zig` by the Misc UI session and recorded in
`docs/HANDOFF-agent-surface-findings.md` §4: for `Ctrl+U` an entry exists
(`{code: 117, final: 'u'}`), the utf8 short-circuit fires only for `.enter`/`.backspace`, the
`plain_text` branch needs empty mods, and the `orelse` fallback that would write `event.utf8` is
unreachable *because* an entry exists. It becomes `ESC[117;5u` and the explicit byte is discarded.

- [ ] **Step 1: Correct both doc comments**

State what the code does: under the kitty protocol ghostty encodes from `key` + `mods` and the
`text:` byte is discarded; the byte is only what the terminal receives under the legacy encoding.
Cite `key_encode.zig` and the handoff doc so the next reader can re-derive it.

- [ ] **Step 2: Record the open question, do not guess at it**

Whether claude's composer *acts* on `ESC[117;5u` is unproven, and it is the live candidate for
the draft-rename bug (box never clears → injection appends → submit sends both). Add a
`docs/FOLLOWUPS.md` entry naming it, and naming the constraint on any probe that settles it: the
probe must **detect** that kitty mode is active and refuse to report otherwise, because a raw pty
can leave claude in legacy mode and a probe that assumes will test an encoder ghostty never uses.

- [ ] **Step 3: Commit**

```bash
git add Sources/FlightDeck/TextInjecting.swift docs/FOLLOWUPS.md
git commit -m "Say what sendControl actually sends under the kitty protocol"
```

Proxy: **not built.** It would see `tool_use` at emission against a versioned format, but is blind
to everything client-side and is observation, never control — injection stays pty-typed
regardless. Whether `ANTHROPIC_BASE_URL` is even honoured for OAuth traffic could not be settled
read-only. It stays a spike behind Task 1, which may make it unnecessary.

## Spike discipline — binding on every probe task above

From `docs/HANDOFF-agent-surface-findings.md` §7, and it indicts this session's work as much as
anyone's: across ~6 review rounds, **every overclaim was the reassuring half of a sentence going
unchecked**. Three wrong conclusions came from probes asserting an outcome for a **configuration
they never established**.

This plan's own record: "TUI dialogs are user-initiated so failing open is safe" (false — claude
raises its own nudges); "`.unknown` falls back to `hasComposerBox`, which refuses a bare shell"
(false, and it is why a fully reviewed branch still typed at a shell); and a probe that reasoned
from raw `\x04` under a bare pty, testing an encoder ghostty never uses.

**Therefore every probe must state the configuration it established and refuse to report a
verdict if it could not establish it.** A Ctrl-U probe that cannot confirm kitty mode must fail,
not conclude. The plan's premise is that probes keep us honest against upstream; one that does
not pin its configuration produces confident wrong answers and is worse than none.

## Spike results

| # | Verdict | Evidence |
|---|---|---|
| B1 | **holds** | Inventory is tractable and the load-bearing set is ~20 items: 12 screen, 8 transcript. Everything else is display-only and may drift. |
| B2 | **holds, with the boundary sharpened** | The *what* (questions, options, `multiSelect`) can move to hooks. The *where* (`focusedRow`, `row(_:reads:)`, `hasNumberedRowAtMarker`) cannot. `.deny` already depends on nothing in either class — one Escape, reads nothing. |
| B3 | **holds, better than assumed** | 42 cells, `diff_baseline`, tier-aware, exits 1/3. Adding claims is adding rows. |
| B4 | **holds — undetected by construction** | No CI, no hooks, no caller but a human. |
| B5 | **holds, but enforces nothing** | Versions recorded in `baseline.json`, `corpus.json`, and six fixture provenance files with sha256 — none verified against the installed binary, none reaching an exit code. |
| B6 | **partially refuted** | Codex has app-server RPC and its rollout, but `CodexEventMapper:31-35` records it **cannot emit `.waiting`** — codex writes nothing to the rollout while an approval list is up. So codex has no structured source for an open dialog, and Task 5's migration is claude-only by necessity. Task 4 must state that rather than let it look like an oversight. |
| B7 | **unresolved, needs execution** | No base-URL flag in `--help`; `--bare`'s text confirms normal mode reads OAuth/keychain. Reinforces deferring the proxy. |

## Verification

- Task 1 is self-verifying: run the matrix against installed 2.1.281 and it should now report drift
  on `claude.openPromptReader` where it previously reported `ok`. **If it does not, Task 1 is wrong.**
- Task 2: a run against a bumped binary with identical cells must exit non-zero.
- Tasks 4–6: `./scripts/test-unit.sh` (whole macOS suite, ~100s, foreground; ignores `-only-testing:`).
- End to end, needs a person: raise a real `AskUserQuestion` on 2.1.281 and confirm the phone
  renders the card — the production symptom that started this.

## Open coordination

**Task 5 is unowned.** It was offered to the Misc UI session, which has since vanished from the
peer list; my reply did not land. It is the one task that fixes a live production outage. This
plan does not absorb it silently — it needs a decision.
