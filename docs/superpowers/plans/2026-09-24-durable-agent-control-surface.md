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

| # | Task | Why it is first/ordered here |
|---|---|---|
| 1 | **Make `claude.openPromptReader` live-driven**, mirroring the codex side of the same row (`capabilities.py:277-370` is the template): drive a real claude to raise an `AskUserQuestion`, read the open prompt through the real `probe.swift`, assert a non-nil question *while the dialog is open*. | This single row is the one that should have caught 2.1.281 and didn't. Everything else is worth less. |
| 2 | **Make version drift fail.** Fold `versions_changed` and `corpus_staleness` into `_exit_code` as a distinct non-zero code, so a new agent build cannot pass silently even when every cell is unchanged. | Without it, a fixture-backed row keeps passing against a binary it never saw. |
| 3 | **Wire the gate into something routine.** No CI exists, so: add `cheap` to `AGENTS.md`'s documented loop, and give `full` a stated cadence plus a recorded "last run at version X". Respect that `full` spends real tokens — this is deliberately not folded into `test-unit.sh`. | A gate nobody runs is not a gate. |
| 4 | **Promote the load-bearing comment pins to rows.** ~15 source comments carry version claims no machine checks — `queuedMessagesHint` "verified 2.1.268", Escape-is-a-denial "2.1.241", the `AskUserQuestion` input shape "2.1.241", codex's paste-detect "0.153.4", and more. Add rows where cheap; where a claim cannot be probed, say so in the comment instead of implying it was checked. | These are the next 2.1.281s. |
| 5 | **Migrate the *what* to hooks.** `OpenPrompt`/`PromptQuestion` derive from the transcript record that moved; the same content arrives structurally via `PreToolUse`. Leaves cursor-position on screen, where it must stay. | Fixes the live outage *and* removes the largest transcript dependency. **Currently unowned — see below.** |
| 6 | **Fix `sendControl`'s false comment**, and decide the encoding question it exposed. The explicit `text:` byte is *discarded* under kitty (traced through `key_encode.zig`); the doc asserting otherwise is true only under legacy. Strong candidate for the draft-rename bug. | Ours to fix, unlike the other surfaces. |

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
