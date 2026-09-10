# Blocked-prompt instrumentation and escape hatch

**Date:** 2026-09-03
**Status:** proposed

## The problem

A session sits at `activity == waiting` with a dialog on its terminal, and the Mac
cannot say which dialog it is. `PromptService.openPrompt` returns `prompt_changed`,
`PromptLifecycleLog` records `unnamed code=prompt_changed`, the Mac pushes
`asserts=open activity=waiting` with no prompt attached, and the phone draws
"Waiting for you" with no controls under it. `scripts/answer-trigger.sh list`
reports no session with an open prompt at all.

Observed four times on 2026-09-02, across two sessions, lasting 24 minutes to
3 hours each.

## Root cause, as far as it is established

Every naming path is a transcript scan — `OpenPrompt.find` for question and
permission cards, `ClaudeOpenPlanGate.find` for plan gates. Neither can name a call
whose record is not on disk.

A controlled repro (throwaway `claude` in a pty, own project dir, no keystrokes)
established the normal behaviour: the `AskUserQuestion` `tool_use` reached the
transcript **3.6 s** after launch and the question then sat unanswered for 30 s+.
Claude persists a blocking call when it *raises* the dialog.

In the failures it did not. phone-reopen's 16:43:09 question was absent from
everywhere under `~/.claude` at 18:27 and appeared — carrying its original
16:43:09 timestamps — only once answered at 18:51:52. So the write was deferred
by over two hours. **This is upstream of Flight Deck and cannot be fixed here.**

### Ruled out by measurement

| Hypothesis | Verdict |
| --- | --- |
| Write-on-completion is the rule | No — probe: on disk at 3.6 s, unanswered 30 s later |
| A `thinking` block defers the write | No — Codex 2's immediately-named calls have identical blocks |
| Body truncated past `TimelineLimits.maxItemBytes` | No — 65,536 limit vs ~1 KB inputs |
| claude version change | No — 2.1.258 since 2026-09-01 |
| `CLAUDE_CODE_CHILD_SESSION` disabling transcript saving | No — not set on fleet processes |

### Explicitly NOT established: a worktree path lag

An earlier reading of this incident blamed `transcriptDirectory` lagging behind a
session that entered a git worktree. That is withdrawn. It rested on treating a
transcript record's `timestamp` as its write time, which the evidence above shows
is invalid. Checked live, the mechanism works: `applyRegistry → retarget` followed
Codex 2 into `.claude/worktrees/adapter-capability-suite` and back out, and
registry `cwd`, `transcriptDirectory` and the live transcript file all agree.

The residual doubt is real but narrow: at 16:43:27–28 the transcript *switched
files* (parent copy's last write 16:43:27, `ExitPlanMode` written to the worktree
copy at 16:43:28.5), so that failure is consistent with either cause. Part A
below settles it next time rather than guessing now.

## Goals

1. Make the two candidate causes — wrong file, or absent record — separable from
   evidence, on desktop and on the phone.
2. Self-correct the one of them that is ours.
3. Give a person stuck behind an unnameable dialog a way out from their phone.

**Non-goal:** fixing the deferred flush. It is upstream. This work makes it
diagnosable and survivable.

## Design

### Part A — Desktop: assert the path, and self-heal

`PromptLifecycleRecord.Event` gains one case, emitted when `unnamed` persists for
**five seconds of continuous unnameability**, and again on a decaying ladder —
30 s, 2 min, 10 min, 30 min, 2 h — while it still does. A brief `unnamed` is the
ordinary race (16:37:57 `unnamed` → 16:37:58 `opened`) and must stay
unremarkable:

```swift
case stuck(
    code: String,
    watched: String?,      // the transcript URL the Mac is reading
    registryCWD: String?,  // ClaudeStatusFile.Entry.cwd for this session's pid
    pathMatches: Bool,     // watched == transcript URL derived from registryCWD
                           // via ClaudeSession's own project-dir encoding, compared
                           // raw — not `comparablePath`. A symlink and its target
                           // encode to two different project dirs, so normalising
                           // here would call a genuine mismatch a match.
    fileAgeMS: Int?,       // now - mtime of the watched file
    lastRecordAgeMS: Int?, // now - newest timestamped record in the tail
    tailRecords: Int       // how many records were scanned
)
```

`pathMatches == false` means the Mac is reading the wrong file — our bug.
`pathMatches == true` with a stale `lastRecordAgeMS` means the record was never
written — upstream. The distinction that cost a day of archaeology becomes one
line in `~/Library/Logs/flight-deck-prompt.log`.

**Why a wall clock and a ladder, not "a second consecutive poll."** This section
originally said two polls, and that was written believing a poll was a *change*.
It is not: `WatchClock.foregroundInterval` is 500 ms and `SessionStatusWatcher.drain`
calls back on every tick, so two polls is 0.5–1 s — the same order as the ordinary
race the threshold exists to exclude, and at that instant the two ages read
identically for a 24-minute stall and for a race that resolves at 1.2 s. The
discriminator quoted above would therefore never have fired at a moment when it
carried information; the absent-record cause would have stayed identifiable only
by the negative (a `stuck` with no `opened` after it). Five seconds rules the race
out, and the later rungs are where a `lastRecordAgeMS` growing in step with the
wall clock states the upstream cause positively. Bounded by construction: six
rungs, each once per episode, and an episode ends the moment the dialog is named
or the tab stops waiting.

**Self-heal.** On `pathMatches == false`, call the existing `retarget(tab, to:)`
immediately rather than waiting for the next registry tick. This is the fix for
the worktree story *if* it is real, and a no-op if it is not. It reuses the
existing retarget path wholesale — no new watcher logic.

Observability rule from `PromptLifecycleLog` still holds: nothing reads a record
back, and no branch is taken on one. The self-heal is a branch on the *registry*,
not on the log record.

### Part B — Mobile: log the phone's own derivation

`SessionTimelineModel.chaseBlockedPrompt` already retries on a bounded schedule
(900 ms → 8 s) and then gives up — the exact moment the phone knows it is in the
pathological state rather than the ordinary race. At exhaustion, write one
`PhoneLog` entry: session id, activity, the call identity it was chasing, retries
spent, and whether the timeline holds any unanswered call at all.

No new transport. `PhoneRequest` already carries phone logs to the Mac, pulled by
`scripts/answer-trigger.sh logs` behind the `FlightDeckAnswerTrigger` gate. The
Mac-side `stuck` record and the phone-side exhaustion record correlate by session
id and wall clock, which is what separates "the Mac never emitted it" from "the
phone never applied it" — the same question `PromptLifecycleLog` was built to
answer, now covering this case too.

### Part C — The Blocked state and its escape hatch

When the chase exhausts with no card, **and the Mac still reports the session
`waiting` with no prompt it can name**, the phone renders a **Blocked** state in
place of the bare "Waiting for you": a short line saying the Mac cannot read this
dialog, and one button.

Those two liveness conditions were missing from the first implementation and were
added in review. Without the first, the exhaustion latch — which only
`chaseBlockedPrompt` clears, and which that method never reaches once the session
stops being `waiting` — leaves Blocked and its destructive Abort drawn on a busy
or idle session indefinitely. Without the second, a phone that merely failed to
build a card draws "This Mac can't read the dialog on screen" over one it can.

**Abort** sends Escape to the terminal. This is not a new capability class — it is
the existing `PromptAnswer.deny` path, which the phone already offers on
permission cards. Per `SessionStore.answerPrompt`, deny is "one key event, no
viewport parse, no row arithmetic," explicitly "the only answer that works on a
screen this build cannot parse at all," and claude records it as a real denial
(`is_error=True`, "The user doesn't want to proceed with this tool use"). It is
precisely the right primitive for a dialog nothing can name.

What is new is only that it carries **no call id**, because there is no nameable
call. That is the entire reason `answerPrompt` cannot serve here.

### Part D — Wire

One new command case (with its handler arms in the same commit — every switch is
exhaustive):

```swift
case abortPrompt(id: UUID, token: UUID)   // op "prompt.abort"
```

Mac handler mirrors `answerPrompt`'s guards minus the call comparison, in the same
order and returning the same codes:

- `unknown_session` — no such tab
- `unsupported_agent` — no `dialogDriver`
- `not_waiting` — **kept, and load-bearing.** A stray Escape into a live TUI is
  not free; `answerPrompt` gates on this for the same reason.
- `prompt_nameable` — **added in review, and load-bearing for the same reason
  `not_waiting` is.** Every input the phone weighs before drawing Blocked is
  phone-side; a body it cannot parse, or a page that never landed, leaves it
  looking identical over a call this Mac names perfectly well, and a blind Escape
  there denies a real tool call the reader was never shown. So the store asks its
  own `openPromptProbe` and refuses when the answer is a call id. Costs codex
  nothing: the probe refuses a codex tab `unsupported_agent`, so those stay
  abortable.
- `unreadable_screen` — no injector, or `injecting` already holds this tab
- duplicate `token` — idempotent, via the existing `answeredPromptTokens`

Then `driver.deny(injector)` and nothing else. No viewport read, so it works on
exactly the screens this feature exists for.

`PromptLifecycleRecord.Event` gains `aborted(code:sent:probe:)` — a sibling of
`answer`, not a reuse of it. `answer` carries `sent` and `open` so a reader can
see which machine was wrong about *which call*; an abort names no call on either
side, and forcing a sentinel through those fields would make "no call id by
construction" indistinguishable from a truncated line. `code` is nil for an
abort that was dispatched, and the refusal code otherwise — so a blind Escape is
as accounted for as a targeted answer.

Two fields beside it, both added in review. `sent` is whether a key was actually
typed: `.duplicate` and `.dispatched` both report no error, so a `code`-only
record cannot say how many Escapes this Mac really sent. `probe` is what this
Mac's own derivation said about the dialog at that instant — `nameable`,
`unnameable-<code>`, or absent — which is the only way the log can answer the
question the escape hatch's safety story rests on: *was this blind Escape aimed
at a genuinely unnameable dialog?*

**Gating.** The Blocked banner and its button sit behind a new Mac preference,
default off, carried as one additive Bool on the fleet snapshot. The Mac refuses
`prompt.abort` when it is off, so an out-of-date phone cannot drive a terminal the
user has not opted in to. Part A and Part B logging are unconditional, matching
`PromptLifecycleLog`'s existing rule that observation is never gated.

## Testing

- **FleetKit / macOS (`scripts/test-unit.sh`):** the `stuck` record's field
  derivation (match and mismatch); self-heal fires on mismatch and not on match;
  `abortPrompt` guard order, each refusal code, token idempotency; the
  second-poll threshold, so a one-poll `unnamed` still emits nothing.
- **Mobile (`scripts/test-ios.sh`):** chase-exhaustion logging; Blocked state
  renders only after exhaustion and only when the gate is on; the button issues
  `prompt.abort` once per token.

Both suites are required — `test-unit.sh` is macOS only, and Part B and C touch
`Sources/FlightDeckMobile`. `test-unit.sh` ignores `-only-testing:` and runs the
full suite (~8 min); budget for it.

## Risks

- **Escape into a session that is not blocked.** Mitigated by the `not_waiting`
  guard and by the gate; the same exposure the existing Deny button already has.
- **Blocked shown during an ordinary slow race.** Mitigated by hanging it on chase
  exhaustion (~18 s) rather than on a single failed fetch.
- **A new snapshot field.** Additive with a default, decoded by older phones as
  absent/off.

## Open decisions

1. Wording of the Blocked line beyond the label itself.
2. Whether Abort should also be offered on a *nameable* dialog (today Deny covers
   that; adding it here would be scope creep).
