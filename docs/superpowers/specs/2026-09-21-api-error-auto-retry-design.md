# Automatic backoff/retry for turns that died on a transient API error

**Status:** design, awaiting review
**Date:** 2026-09-21

## 1. The problem

A turn that dies on a capacity-shaped API failure leaves a session stopped with a red
badge and nothing else happening. The agent's own retry loop has already given up by that
point, so nothing will ever revive the turn — the user has to notice the badge and type
something. A session left alone overnight during an outage is simply dead until morning.

This adds an opt-in loop that waits and re-nudges the agent until the API comes back.

## 2. What already exists (and what this therefore does not build)

- **`SessionAPIError`** (`Sources/FleetKit/SessionAPIError.swift`) — normalised `status`,
  `kind`, `isTransient`; already persisted, already on the wire, already rendered as the
  sidebar badge and the phone's status glyph. Its own doc records that `isTransient` is
  *"carried but not yet rendered… read by nothing today"*. This feature is its first reader.
- **`inject()`** (`SessionStore.swift:5365`) — the single funnel for typing into a pty.
  Gated on `AgentAdapter.textChannel`, re-entrancy-guarded via `injecting: Set<UUID>`,
  and it owns the kill-line/settle/yank draft dance.
- **`pendingPrompts` / `DeferredPrompt`** (`SessionStore.swift:1385`) — one-per-tab deferred
  text with a deadline, flushed on the registry tick by `flushPendingPrompts()`, and
  cancelled by `cancelSupersededPrompts()` the moment the session goes `busy` or `waiting`.
- **The registry tick** — `flushPendingPrompts` is already driven by it rather than by
  status changes, *"so gating the retry on one would strand it"* (`SessionStore.swift:5792`).

The retry loop is a scheduler on top of these, not a parallel implementation of them.

## 3. Evidence from the codex probe (2026-09-21)

Established by driving a real `codex` TUI against a local upstream returning `429`
(rig and transcript in the session scratchpad; nothing added to the repo):

- **Codex writes the error into the rollout**, as a field on the `task_complete` record
  that `CodexEventMapper` already parses:

  ```json
  {"type":"event_msg","payload":{"type":"task_complete","turn_id":"…",
    "error":{"message":"exceeded retry limit, last status: 429 Too Many Requests",
             "codex_error_info":{"response_too_many_failed_attempts":{"http_status_code":429}}}}}
  ```

  So codex needs **no app-server call**, and `CodexRuntime`'s deliberate file-only design
  (`CodexRuntime.swift:5-8`) is preserved untouched. No writer-lock hazard.
- **`ThreadStatus` is never `systemError` for an API failure** — it reads `notLoaded`/`idle`.
  Building the codex signal on `CodexThreadStatus.swift:39`, which that file's comment
  invites, would have detected nothing. Do not use it.
- **The rollout spells the payload snake_case** (`codex_error_info`, `http_status_code`)
  while the app-server schema is camelCase. The parser must use the file's spelling.
- **Codex retries internally and says so** (`response_too_many_failed_attempts` = "reached
  the retry limit"), exactly as claude does. Confirmed on the wire: `request_max_retries=1`
  produced precisely two `POST /v1/responses`. Our backoff is second-order for both agents.
- **The composer is present and empty after the failure** (`› Ask Codex to do anything`
  plus its footer), so `CodexTextChannel.hasComposerBox` passes and the nudge is typeable.

## 4. Design

### 4.1 Signal: one new producer, no new observation channel

`CodexEventMapper.events(inRolloutLine:)` gains an `.apiError` emission on its existing
`task_complete` arm — set when `payload["error"]` is present, cleared (`.apiError(nil)`)
when a `task_complete` carries none. `turn_aborted` is left alone: a user interrupt is not
an API failure.

Mapping into the existing struct: `http_status_code` → `status`; the `codex_error_info`
variant name → `kind` (verbatim, honouring that field's "never matched against an enum"
rule for *display*); the variant identity → `isTransient` via §4.2.

Claude's producer is unchanged — it already works.

### 4.2 Policy: a new adapter capability, failing closed

Following the house pattern of `textChannel` / `dialogDriver` — an optional static on
`AgentAdapter`, dispatched through the `AgentID` switch in `AgentAdapter.swift:426`, never
asked of an instance:

```swift
static var turnRecovery: AgentTurnRecovery? { get }

protocol AgentTurnRecovery {
    /// Whether this failure is worth retrying. An unrecognised kind returns false.
    func retries(_ error: SessionAPIError) -> Bool
    /// The text typed to revive the turn.
    var resumeText: String { get }
}
```

- **Claude** — `retries` is `error.isTransient` (the CLI's own predicate, already parsed).
- **Codex** — an **allowlist** of transient variants, spelled as the *rollout* spells them
  (§3: snake_case, which is what `kind` holds — not the app-server's camelCase):
  `rate_limit_exceeded`, `server_overloaded`, `internal_server_error`,
  `response_too_many_failed_attempts`, `response_stream_connection_failed`,
  `response_stream_disconnected`, `http_connection_failed`.
  Everything else — `unauthorized`, `bad_request`, `context_window_exceeded`,
  `usage_limit_exceeded`, `cyber_policy`, `misalignment_policy_violation`, `sandbox_error`,
  `other`, **and any kind codex adds later** — does not retry.

  The exact spelling of each variant must be re-confirmed against a captured record during
  implementation rather than transcribed from this list: §3 captured
  `response_too_many_failed_attempts` directly, and the rest are converted from the
  app-server schema's camelCase by rule, not by observation.

**One source of truth for the codex allowlist.** `CodexTurnRecovery` owns it, and the
rollout parser calls that same predicate to populate `isTransient` — so the persisted flag
and the retry decision can never disagree. The adapter remains the authority (that is the
point of the capability); the parser is a caller, not a second copy of the policy.

Failing closed is the deliberate choice: a vocabulary this codebase does not control must
never be able to cause unattended typing into a terminal by growing a new member.

`resumeText` is `"Keep going"` for both, reusing `SessionStore.resumePrompt` rather than
inventing a second vocabulary for the same act.

A `nil` `turnRecovery` **is** the refusal, exactly as a `nil` `textChannel` is — so an agent
added later retries nothing until someone builds and tests its classifier.

### 4.3 Schedule: ramp to a floor, indefinitely

A literal ladder, in the style of `stuckPromptReportLadder`:

```swift
static let retryBackoff: [TimeInterval] = [30, 60, 120, 300, 480]
static let retryBackoffFloor: TimeInterval = 900
```

Attempt *n* waits `retryBackoff[n]`, or the floor once the ladder is exhausted — so a long
outage is ridden at one attempt per 15 minutes for as long as it lasts. Each delay carries
±10% jitter so a fleet of tabs that all died on the same 529 does not re-nudge in lockstep.

**Unbounded retry is only safe because of the stops**, which are the load-bearing half of
this section:

| Stop | Mechanism |
|---|---|
| Not transient | §4.2 allowlist, evaluated before arming |
| Agent can't be typed into | `textChannel == nil` / `turnRecovery == nil` |
| The session started working | `.progressed` clears `apiError`; `cancelSupersededPrompts` drops an in-flight nudge on `busy`/`waiting` |
| The user got there first | same path — their typing makes it busy |
| Tab closed | state cleared with the tab, as `acceptedPromptTokens` is |
| Preference off | checked at arm time *and* at each tick, so a mid-outage toggle stops it |
| Agent process gone | `inject`'s composer gate defers forever and types nothing |

### 4.4 Mechanism: a tick-evaluated timer that feeds the existing queue

No new typing path. When the tick finds `now >= nextRetryAt` for an armed tab it drops a
`DeferredPrompt(text: resumeText)` into `pendingPrompts` and advances the rung. The existing
`flushPendingPrompts` then does the work it already does — wait for a composer, defer behind
a pending rename, cancel if the session started on its own, drop on its 120s deadline (a
miss is harmless: the next rung tries again).

This buys the cancel-on-busy semantics, the rename interlock, and the re-entrancy guard for
free, and adds no second way to type into a terminal.

**Amended 2026-09-21, before implementation: the tick cannot be the registry scan.**
The first draft of this section said "on the registry tick", meaning `applyRegistry`'s
`defer` block, where `flushPendingPrompts` already lives. That is wrong, and wrong in the
way this project has a standing rule against: `applyRegistry` is driven only by
`SessionStatusWatcher`, which is built per account **only for agents with a status
registry** (`SessionStore.startStatusWatching`, `startWatching(tabID:)`, both gated on
`session.agent.hasStatusRegistry` — true for claude, false for codex). A fleet with no
claude tab never ticks, so a retry armed on a codex tab would wait forever. Shipping that
would make an all-agents feature claude-only in practice while looking correct in review.

Instead: extract that `defer` body into a `maintenanceTick()` — `flushPendingRenames`,
`flushPendingPrompts`, `flushPromptQueue`, plus the new `flushRetryBackoff` — and call it
from two places: `applyRegistry`'s `defer` (unchanged for claude) and a new registration on
the shared `WatchClock`, using the `clock.add(owner) { … }` idiom the sleep controller
already uses at `SessionStore.swift:1658`. All four flushes are idempotent and
deadline-guarded, and `inject` is re-entrancy-guarded, so running them from two sources in
the same instant is safe.

**This incidentally fixes a pre-existing gap and must be tested as such, not slipped in:**
phone-sent prompts (`promptQueue`) and deferred renames on a codex-only fleet have the same
starvation today. A test must assert a codex tab's queued prompt is typed with no claude tab
anywhere in the store.

### 4.5 Wire and UI: extend the existing field, add no event case

Retry state rides **inside `SessionAPIError`** as two new optional fields:

```swift
public var retryAttempt: Int?     // 1-based, nil when not armed
public var nextRetryAt: Date?     // absolute, never a countdown
```

This is the whole reason the change is small:

- **No new `FleetEvent` case, tag, `WireCoding` arm, `SnapshotApplication` arm, or
  `FleetReplay` `FoldKey`.** `apiErrorChanged` already carries the struct and is already
  folded last-write-wins.
- **`setAPIError` stays the single writer** (`SessionStore.swift:1135`), so the
  mutation-and-emit pairing that `FleetReplicator`'s DEBUG drift assertion depends on holds
  automatically. Its `apiErrors[id] != error` guard also gives correct emit-once semantics:
  one event per attempt, because only `retryAttempt`/`nextRetryAt` changed.
- **Old phones degrade cleanly.** `SessionAPIError`'s hand-written `init(from:)` already
  uses `decodeIfPresent(…) ?? default` on every field; a new tag would instead have thrown
  in `FleetEventTag` and torn down the socket.
- **Absolute, not remaining.** `nextRetryAt` is a timestamp so the value changes once per
  attempt rather than once per second; the client does the arithmetic, as
  `WirePlanGate.startedAt` already does.

`SessionAPIError.label` gains the retry clause, which is what updates the Mac tooltip, the
Mac accessibility label, and the phone's VoiceOver string in one edit — the reason that
function exists.

**Mac sidebar:** the badge keeps the red triangle (the error is still true) and the tooltip
reads `Stopped — API error 529 (overloaded) · retrying, attempt 2`. The sidebar row is a flat
`HStack` with no subtitle slot, and `SessionSidebar.swift:17` explicitly rejects a
`TimelineView` over rows, so **the Mac shows no live countdown** — attempt number only. A
per-second tooltip would not refresh mid-hover anyway.

**Phone:** a non-tappable banner in the existing top `safeAreaInset`
(`SessionTimelineScreen.swift:350`), beside `planGateBanner` and styled to match, reading
`Retrying — attempt 2, next in 1m 30s`. This one *does* count down, via a
`TimelineView(.periodic(from:.now, by: 1))` wrapped around the banner alone and present only
when `nextRetryAt != nil`, so it costs nothing in the normal case — the same argument
`PhonePresenceBadge` makes for its `onAppear` animation.

The existing in-list `activityFooter` error row is left as is.

### 4.6 Restart behaviour

Retry state is **not persisted**: `restore()` strips `retryAttempt`/`nextRetryAt` from the
loaded `apiError`. A relaunch re-arms from the *floor* (15 min), not rung 0 — a restart is
not evidence that the API recovered, and arming a whole restored fleet at 30s would produce
exactly the launch-time burst of typing that `cancelSupersededPrompts`' boot-flicker note
already warns about. Gated on the same conditions as a live arm.

### 4.7 Preference

Global, agent-agnostic, following the four-part pattern in `PreferencesStore`:
`Bool?` on `ShellPreferences` (optional so an existing `preferences.v1` blob still decodes),
default resolved in a store accessor, and a `Toggle` in **Shell & Environment** in a new
`Recovery` section below `Sleep` — the pane that already hosts the cross-agent
session-lifecycle toggles. Default **off**.

Caption must say what it does in plain terms, including that it types into the session.

## 5. Testing

TDD throughout; every test written to fail against the current code first.

- **Codex parser** — fixture is the real `task_complete` record captured by the probe, plus
  a clean `task_complete` (clears) and a `turn_aborted` (no-op).
- **Classifier** — every allowlisted codex kind retries; every permanent one does not; an
  invented unknown kind does not (the fail-closed assertion).
- **Ladder** — rung progression, floor saturation, jitter within bounds.
- **Arming and stops** — one case per row of §4.3's table, including the preference being
  switched off mid-backoff.
- **No double-typing** — a tick inside an in-flight settle window types once.
- **Wire** — round-trip with and without the new fields; a payload lacking them decodes
  (the old-client guarantee).
- **Drift** — the existing `FleetReplicator` assertion must stay green, which is the real
  test that `setAPIError` remained the only writer.
- **Phone** — banner presence/absence and label text in `FlightDeckMobileTests`. Runs under
  `./scripts/test-ios.sh`, not `test-unit.sh`; both suites must pass.

## 6. Rejected alternatives

- **Re-sending the last user prompt** instead of a nudge — duplicates an instruction the
  agent already has in context.
- **Restarting the CLI via `resumeCommand`** — loses scrollback and, for codex, walks into
  the writer-lock refusal recorded in `docs/FOLLOWUPS.md:445`.
- **A new `FleetEvent` case for retry state** — a new `FleetEventTag` raw value throws in an
  older phone's decoder and tears down the socket; §4.5 avoids the break entirely.
- **Driving codex off `ThreadStatus.systemError`** — probed and disproved (§3).
- **A denylist for codex kinds** — fails open; a new permanent error kind would be retried
  indefinitely against a terminal.
- **An error case on `SessionActivity`** — `apiError` is deliberately an orthogonal axis, and
  `SessionTimelineScreen.swift:854` records why it must be checked *before* activity.

## 7. Open question for review

§4.6 (re-arm at the floor after a relaunch) is the one behaviour chosen on judgement rather
than evidence. The alternative — never re-arm after a restart, requiring the user to nudge
once by hand — is safer and less useful.
