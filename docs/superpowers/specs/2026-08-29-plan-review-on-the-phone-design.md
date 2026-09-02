# Plan Review on the Phone — Design

**Date:** 2026-08-29
**Status:** design, pre-implementation
**Scope:** read and annotate an open `ExitPlanMode` gate from the phone, and resolve it.

A plan gate is the longest a Flight Deck session ever blocks — Plannotator registers its hook
with `timeout: 345600`, four days — and it is the one blocked state the phone cannot see at
all. This closes that hole and makes the gate answerable from a pocket.

## 1. Findings that constrain the design

Every item was verified on this machine on 2026-08-29, against a **live gate** that was open
while the measurements were taken (`plannotator` pid 18418, port 54232, `mode: "plan"`,
`project: "flight-deck"`, started 17:40:36Z — 33 minutes blocked and counting).

1. **A plan gate reports `busy`, not `waiting`. This is the bug.** The `claude` process behind
   that gate is pid 66955, and for the whole 33 minutes its registry file said:

   ```
   ~/.claude/sessions/66955.json → "status": "busy"
   ```

   `OpenPrompt.find` gates on `activity == "waiting"`, so it returns `nil` and the phone draws
   **no card**. The session renders as working. There is no spinner-versus-blocked distinction
   to be made on the phone today, because the two states are byte-identical in the only file
   that reports them. A human could be needed for four days and the fleet would look busy.

   This is why the gate cannot be detected the way `AskUserQuestion` is. It is not a matter of
   adding a case to `OpenPrompt`; the precondition every case shares is false here.

2. **The gate is a local HTTP server with a documented API, and Flight Deck can drive it.**
   Extracted from the `plannotator` binary and confirmed against the live server:

   | Call | Effect |
   |---|---|
   | `GET /api/plan` | `{plan, origin, permissionMode, repoInfo, previousPlan, versionInfo, projectRoot, …}` |
   | `POST /api/external-annotations` | `{source, type, text, originalText}` — inline or global comment, live on arrival |
   | `DELETE /api/external-annotations?source=…` | drop everything one source posted |
   | `GET /api/external-annotations/stream` | SSE of annotation mutations |
   | `POST /api/approve` | `{feedback?}` → `resolveDecision({approved: true, feedback})` |
   | `POST /api/deny` | `{feedback}` → `resolveDecision({approved: false, feedback})` |

   `GET /api/plan` against the live server returned the real plan, 6,342 characters. The hook
   then prints `{"permissionDecision":"allow"}` or
   `{"permissionDecision":"deny","permissionDecisionReason":<feedback>}`.

   **Approve carries feedback too.** Approving with notes is a first-class outcome, not a
   workaround — which is what makes "read it, mark it up, and say yes anyway" expressible.

3. **The gate announces itself in a registry Flight Deck can read.**
   `~/.plannotator/sessions/<pid>.json` holds `{pid, port, url, mode, project, startedAt,
   label}`. The `pid` is `plannotator`'s, and its **parent is the `claude` process**
   (18418 → 66955 → `claude`, verified with `ps`). Flight Deck already keys sessions by that
   pid via `ClaudeStatusFile.Entry.pid`, so attribution is exact rather than inferred from
   `cwd` — which matters here, because this checkout runs many sessions from one directory.

4. **The plan is already on the phone.** The `ExitPlanMode` `tool_use` record carries the plan
   markdown in `input.plan`, and the phone receives it as `TimelineItem.Body.text` on a
   `.toolCall` item — the same way `AskUserQuestion`'s input arrives for `PromptQuestion`.
   `TimelineLimits.maxItemBytes` is 65,536; plans measured here run 3–15 KB, so the body is
   whole. The new northbound traffic is therefore **the fact of the gate**, not the plan text.

5. **Block-tap annotation is safe on real plans.** Splitting the live 6,342-character plan on
   blank lines, keeping fences intact: **30 blocks, median 221 characters, zero duplicates.**
   Exactly one block occurs more than once as a substring — `---`. Plannotator pins comments by
   matching `originalText` as a verbatim substring and its own docs say "longer is safer than
   shorter", so whole blocks are a *better* fit for the matcher than hand-dragged selections.

6. **Plannotator's own remote path is not available here.** `--tailscale` exists only on
   `review` and `annotate`, not the hook, and it shells out to `tailscale serve`; this machine
   has `Tailscale.app` but no `tailscale` CLI on `PATH`. `PLANNOTATOR_REMOTE=1` would bind
   off-loopback, but the API is explicitly **unauthenticated** ("No authentication", from its
   own generated docs), so publishing it is a real regression, not a shortcut.

**Taken on report, not verified here:** that Claude Code reports `busy` for *every* blocking
`PermissionRequest` hook rather than this one specifically. Task 1 pins it either way; the
design does not depend on which is true, because it never consults the status file for this.

## 2. What this delivers

A plan gate becomes a visible, answerable state on the phone:

- the fleet shows the session as **blocked on a plan**, not busy, and notifies;
- the plan renders with `TimelineMarkdown`, in the theme the timeline already uses;
- tapping a block attaches a comment to it;
- **Approve** or **Request changes**, either one carrying the accumulated notes.

## 3. Two tiers, chosen by what is actually running

The tier is a property of the gate, decided on the Mac, and the phone is told which it got.

**Tier 1 — a Plannotator gate is live.** Full inline annotation. Comments POST to
`/api/external-annotations` as they are written, so they appear on the Mac's browser
immediately and can be edited there. The verdict POSTs to `/api/approve` or `/api/deny`.

**Tier 2 — no Plannotator.** `ExitPlanMode` falls through to Claude Code's own TUI permission
prompt, so the session genuinely *is* `waiting` and `OpenPrompt.find` already returns
`.permission(callID:tool:"ExitPlanMode":summary:)`. The phone reads the plan from the
transcript body, collects the same notes, and resolves through the paths that exist today.
**The order is fixed and matters:** Escape closes the call first, and only then do the notes go
as an ordinary `session.prompt`. Reversed, the text would be typed into a bar with a dialog
still up — the exact failure `SessionStore.inject` already guards. Approving with notes is
therefore two steps in Tier 2 and one in Tier 1. Inline pinning is unavailable and the
screen says so, once, rather than offering a gesture that would go nowhere.

Tier 2 is not a stub. It is what the feature degrades to on a machine without Plannotator, and
it is the only tier whose plumbing already exists.

## 4. Discovery, and why not a hook of our own

`PlanGateWatcher` on the Mac polls `~/.plannotator/sessions/*.json`, keeps entries with
`mode == "plan"` whose `pid` is alive, and maps each to a Flight Deck session by parent pid.

The 2026-08-18 mobile companion spec (§9) proposed shipping our own `PermissionRequest` hook
and flagged the cost: "Registering the hook writes to claude's settings, which is a side effect
on the user's environment." Reading a registry has no such cost. It also does not compete with
Plannotator for the gate — two `PermissionRequest` hooks on one matcher is a decision race, and
this design has no opinion strong enough to justify one.

**Nothing here is a keystroke.** The `AskUserQuestion` path had to become a remote keyboard
because its dialog exists only as pixels in a terminal; every parsing risk in `AnswerPlan` and
`ChoiceDialog` follows from that. A plan gate has a real API, so this is a remote *control*:
the verdict is a two-value enum and the notes are content, never a label matched against a
screen. There is no misread to defend against, and no interlock to get right.

## 5. The annotation model

`PlanBlocks` lands in `FleetKit`, beside `OpenPrompt` and for its stated reason — **the Mac and
the phone must not run two versions of this rule.** The phone decides what to draw a tap target
around; the Mac decides what `originalText` to POST. If those disagree, a comment silently
detaches from the phrase it was written about.

Splitting: blank-line separated, fenced code kept whole, headings and list items their own
blocks. Two refusals, both because a wrong pin is worse than no pin:

- **A block that is not unique in the plan is not a target.** Verified with
  `plan.count(block) == 1` rather than assumed. On a real plan this excluded only `---`.
- **A thematic break is never a target.** There is no prose to comment on.

A block that fails either test still renders; it just takes no tap. Anything a reader wants to
say about it goes in a global comment, which needs no anchor.

## 6. Wire protocol

Northbound, on the session snapshot: `planGate` — `{callID, tier, plan?, truncated, startedAt,
annotationCount}`. `plan` is populated in Tier 1 from `GET /api/plan`, which is authoritative
and survives a plan larger than `maxItemBytes`; in Tier 2 it is omitted and the phone reads the
transcript body it already holds.

Southbound, two commands in the established shape — `op`-namespaced, flattened, token-carrying:

- `plan.annotate` — `{id, token, call, kind: inline|global, text, block?}`
- `plan.resolve` — `{id, token, call, verdict: approve|deny, feedback?}`

`token` gives the same idempotency `answeredPromptTokens` gives `prompt.answer`: a retry that
lands is an answer that landed. `block` is the block's **index**, not its text — the Mac holds
the plan and resolves the index against its own copy, so a phone cannot name a phrase the Mac
never saw. Same principle as `PromptAnswer.label` being a cross-check, applied one level up.

## 7. Failure modes

- **Answered on the Mac first.** `waitForDecision` resolves once; the second POST loses. The
  Mac treats a resolved gate as `duplicate` — an `ack`, because from the phone's side an answer
  that arrives after the gate closed is an answer that landed.
- **The gate vanishes mid-review** (hook killed, session ended). The registry entry's `pid`
  goes dead; the phone's screen becomes read-only with a stated reason rather than a dead
  Approve button.
- **The plan is revised.** A denied plan comes back as a new `ExitPlanMode` call with a new
  `callID`, and `/api/plan` carries `previousPlan` and `versionInfo`. Slice 1 shows the new
  plan and drops stale annotations; **diffing against the previous version is out of scope.**
- **A comment fails to match.** Plannotator falls back to sidebar-only, silently — the POST
  succeeds either way. Since §5 guarantees a verbatim unique substring this should not occur,
  and the design does not try to detect it: **the POST response shape was not verified**, and
  Task 2 must read it before the phone claims a pin it cannot confirm. Until then a comment is
  reported as sent, never as anchored.

## 8. Testing

- `PlanBlocksTests` — splitting, uniqueness refusal, fence integrity, over the captured plan
  from the live gate as a fixture.
- `PlanGateWatcherTests` — registry parse, dead-pid filtering, parent-pid attribution, and the
  shared-checkout case where two sessions share a `cwd`.
- `PlanResolveTests` — token idempotency, resolved-gate `duplicate`, dead-gate refusal.
- A recorded `plannotator` server double for the API contract, so the tests do not need a live
  gate. The contract it encodes is §1.2, which was read off the binary and confirmed against a
  running server.

## 9. Out of scope

Version diffing; editing the plan text itself; Plannotator's file browser, code navigation and
guided-review export; anything that publishes its API beyond loopback.
