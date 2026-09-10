# Phone prompt: delivery signal + inline transcript ghost

## Context

A phone prompt sent while an agent is mid-turn *feels* "queued until the agent is completely
idle." A long investigation (see `memory/phone-prompt-midturn-investigation.md` and the SDD
ledger) proved this is **not** a delivery bug: driving a real `session.prompt` frame over the
actual `FleetClient`→TLS→`FleetService.apply`→`SessionStore.submitPrompt`→`inject` path at a
real busy Claude tab shows `inject=true`, a wire `ack`, the prompt **queued into Claude
mid-turn** (`❯ Press up to edit queued messages`), and Claude **running it at turn-end**. The
Mac types the prompt into the agent immediately; nothing waits for idle.

What the user actually sees as "queued until idle" is the **phone's outbox display**: the
`.accepted` row renders *"Waiting for your Mac to type this"* (`PromptComposer.swift`) for the
whole turn, because it clears only when `PromptOutbox.reconcile` finds the message in the
transcript — which, for a mid-turn-queued prompt, is at turn-end. The bare `ack` cannot
distinguish "typed into the agent" from "not yet typed," so the phone shows the alarming
"Waiting" copy the entire time.

**Goal.** When the Mac actually types a phone-sent prompt into the agent, tell the phone, and
show a single inline **ghost/placeholder entry in the transcript** styled as pending, dropped
the moment the real message lands. Show the ghost **only once delivered**; a rejected prompt
shows a failure and never draws a ghost. Delivery behavior is unchanged (it is correct). The
mechanism is adapter-agnostic.

## Design

### 1. Mac → phone signal: `FleetEvent.promptTyped(id:token:)`

Model it exactly on the existing `FleetEvent.promptExpired(id:token:)` (its direct precedent —
a per-screen outbox notification carrying the token, not fleet state):

- Add `case promptTyped(id: UUID, token: UUID)` to `FleetEvent` (`Sources/FleetKit/FleetEvent.swift`)
  and to its exhaustive `sessionID` / `projectID` switches.
- **Emit** it from the `onSent` closure inside `SessionStore.flushPromptQueue(_:)`
  (`Sources/FlightDeck/SessionStore.swift`, ~line 3974) — the moment `inject`'s settle confirms
  the pty received the text + Return. This is parallel to the `.promptExpired` emit already in
  that function (~3956), and it is adapter-agnostic: both `ClaudeTextChannel.submit` and
  `CodexTextChannel.submit` invoke `onSent()` only after `sendReturn()`.
  `emit([.promptTyped(id: id, token: head.token)])`.
- **Drift check:** add a no-op `case .promptTyped: return` to `FleetSnapshot.apply(_:)`
  (`Sources/FleetKit/SnapshotApplication.swift`), exactly as `.promptExpired` is a no-op. It
  carries no fleet state, so `FleetReplicator.checkForDrift` stays in lockstep. (This is why
  `submitPrompt`'s "adds no mutation site" note is not violated — no `repos`/`statuses` change
  accompanies the event.)
- **Replay/resume:** give it no `FoldKey` (like `.promptExpired`), so `FleetReplay` keeps every
  occurrence verbatim; a reconnect beyond the event ring gets a `.resnapshot`, not a stale
  ghost — the correct behavior.
- Broadcast and resume then work automatically (`FleetService.replicator.onEvents` →
  `server.broadcast(.event(...))`; `FleetConnector.onEvent` on the phone).

### 2. Phone outbox: a fourth state, `.delivered`

In `Sources/FleetKit/PromptOutbox.swift`:

- Add `.delivered` to `PromptOutboxEntry.State`. State machine:
  `.sending → .accepted` (on `ack`) `→ .delivered` (on `promptTyped`) `→` removed (on
  `reconcile`); `.failed(reason)` from `err` or `promptExpired`. Update the "three states and no
  fourth" doc comment — the Mac can now report the typed moment, which is exactly the distinction
  that comment said was unavailable.
- Add `mutating func deliver(_ token: UUID)` (idempotent: a no-op if the entry is missing or
  already delivered/removed — covers replay and duplicates).
- Wire it: in `FleetModel`'s `connector.onEvent` handler add
  `case .promptTyped(let id, let token): timelineModels[id]?.promptTyped(token)` (beside the
  existing `.promptExpired` arm), and `SessionTimelineModel.promptTyped(_:)` calls
  `outbox.deliver(token)` — parallel to `promptExpired(_:)`.
- `reconcile(with:)` is unchanged: it still retires the entry (from any non-failed state) when a
  matching `.userTurn` appears in the transcript.

### 3. Inline transcript ghost — rendered from `.delivered` entries, `TimelineFeed` untouched

The ghost is a **view-layer** concern; it never enters `TimelineFeed`:

- In `SessionTimelineScreen.entries` (`Sources/FlightDeckMobile/SessionTimelineScreen.swift`,
  ~line 421), after mapping `model.feed.items` to `Entry`s, **append** one synthetic ghost
  `Entry` per outbox entry currently in `.delivered` state, in send order, at the bottom
  (most-recent end). The ghost `Entry`'s id is namespaced (`"ghost:<token>"`) so it never
  collides with a file-backed `"<offset>#<index>"` id. Render it with a distinct pending
  treatment and copy (e.g. "Queued to your agent").
- `TimelineFeed` and its `merge` are **not** modified — the ghost stays out of `feed.items`,
  preserving the feed's invariants (file-backed ids, cursors that only widen from real
  `TimelinePage` fetches). *Rejected alternative:* minting a sentinel id into the feed — it
  rides the `order(of:)` `(.max,.max)` fallback by accident and would force an audit of every
  id-parsing site; not worth the fragility.
- **Drop:** when the turn ends and Claude writes the message, the next `fetch` does
  `feed.merge(page)` (the real `.userTurn` appears) then `outbox.reconcile(with:)` (the delivered
  entry is retired) in one pass — so the ghost disappears in the same render the real item
  appears in: no duplicate, no gap.
- **What each state shows.** The below-composer outbox area (`PromptComposer.outboxRow`) now
  renders **only `.failed` entries** (actionable: retry/dismiss). `.sending`/`.accepted`
  (pre-delivered) show **no** dedicated row — the composer's disabled send (`isSending`) is the
  only cue, and the alarming "Waiting for your Mac to type this" copy is gone. `.delivered`
  renders as the inline transcript ghost (§3) and nothing below the composer. So there is
  exactly one place a queued prompt appears: the ghost.
- **Pre-delivered window** is honest: for the common mid-turn-empty-box case `.delivered` is
  near-instant; for a deferred prompt (busy box already holding a draft, or a `waiting` dialog)
  there is a short window with no ghost and no row — correct, because it genuinely has not been
  typed into the agent yet.

## Failure & edge behavior

- `err` (`notRunning` / `unsupportedAgent` / `rejected`) → `outbox.fail` → failure row with
  retry/dismiss; no ghost ever drawn.
- `.promptExpired` (15-min window elapsed before it could be typed) → `outbox.fail`; the ghost
  never appeared because it was never delivered.
- Replay of `.promptTyped` after reconnect, or a duplicate → `deliver` is idempotent.

## Testing

- **FleetKit unit:** `PromptOutbox` transitions — `deliver` sets `.delivered`, is idempotent,
  `reconcile` drops a delivered entry, `fail` works from `.delivered`. `FleetSnapshot.apply(.promptTyped)`
  is a no-op. `FleetReplay` keeps `.promptTyped` verbatim (no fold key).
- **FlightDeck unit:** `SessionStore` emits `.promptTyped(id,token)` from `flushPromptQueue`'s
  `onSent` — a store test with a stub `AgentTextChannel` whose `submit` drives the settle/`onSent`,
  asserting the event on the emit sink. (This is the regression test the investigation lacked: it
  exercises the emit at the real typed moment, not a fixture string.)
- **Mobile unit:** `SessionTimelineModel.promptTyped(token)` sets delivered; `SessionTimelineScreen.entries`
  includes a `ghost:<token>` entry for a delivered outbox entry and omits it once `reconcile` has
  retired it.
- **Integration:** extend `TimelineLoopbackTests` / a prompt loopback — send a `session.prompt`,
  assert an `ack`, then assert a `.promptTyped` event arrives for the same token.

## Scope / non-goals

- No change to *delivery* behavior — it is already correct. No "interrupt the current turn" behavior.
- Adapter-agnostic: the signal fires from `inject`'s `onSent`, shared by Claude and Codex.
- **Cleanup (this branch):** keep the permanent `.typing` instrumentation
  (`PromptLifecycleRecord.typing`, `logPromptTyping`, `promptTypingComposerState`, the
  `flushPromptQueue` logging); **strip** the temporary `#if DEBUG` diagnostic hooks
  (`startViewportDiagnosticsIfRequested`, `startPhonePromptSimulationIfRequested`,
  `startLoopbackPromptTestIfRequested`, and their retained `loopbackTest*` properties + init calls)
  before this merges to master.
