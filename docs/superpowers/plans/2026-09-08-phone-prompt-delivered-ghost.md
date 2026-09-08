# Phone prompt: delivery signal + inline transcript ghost — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Show a phone-sent prompt as an inline "ghost" entry in the transcript the moment the Mac types it into the agent, dropped when the real message lands — replacing the misleading "Waiting for your Mac to type this" row.

**Architecture:** New `FleetEvent.promptTyped(id:token:)` emitted from the Mac at the exact moment `inject` types the prompt into the agent (modeled on the existing `.promptExpired`). The phone marks the outbox entry `.delivered` and renders a single ghost entry in the transcript view, kept entirely out of `TimelineFeed`.

**Tech Stack:** Swift, FleetKit (shared wire), FlightDeck (macOS app), FlightDeckMobile (iOS app).

**Spec:** `docs/superpowers/specs/2026-09-06-phone-prompt-delivered-ghost-design.md`

## Global Constraints

- **Wire atomicity:** the new `FleetEvent` case and every exhaustive `switch` arm over `FleetEvent` land in ONE commit (Task 1) — the code will not compile otherwise.
- **Two test targets:** changes under `Sources/FlightDeckMobile` are verified with `scripts/test-ios.sh`; FleetKit/FlightDeck changes with `scripts/test-unit.sh`. Both build the full suite (~8 min each); `-only-testing:` is ignored. Run tests in the FOREGROUND.
- **Delivery behavior is unchanged** — this is display-only. No change to when/whether the Mac types a prompt; no "interrupt the turn."
- **Adapter-agnostic:** the signal is emitted from `inject`'s shared `onSent`; do not special-case Claude vs Codex.
- **Model the new event on `.promptExpired(id:token:)`** everywhere (same shape: `id: UUID, token: UUID`); read the `.promptExpired` arms as the copy template.

---

### Task 1: Wire — `FleetEvent.promptTyped` (atomic)

**Files:**
- Modify: `Sources/FleetKit/FleetEvent.swift` (enum case + `sessionID`/`projectID` switches)
- Modify: `Sources/FleetKit/WireCoding.swift` (`FleetEventTag` + encode + decode)
- Modify: `Sources/FleetKit/SnapshotApplication.swift` (no-op `apply` arm)
- Test: `Tests/FlightDeckTests/` — add `PromptTypedWireTests.swift` (FleetKit types are exercised from the FlightDeck test target)

**Interfaces:**
- Produces: `FleetEvent.promptTyped(id: UUID, token: UUID)`; wire tag `"prompt.typed"`.

- [ ] **Step 1: Write the failing test** — `Tests/FlightDeckTests/PromptTypedWireTests.swift`:

```swift
import XCTest
@testable import FleetKit

final class PromptTypedWireTests: XCTestCase {
    func testPromptTypedRoundTripsOnTheWire() throws {
        let id = UUID(); let token = UUID()
        let event = FleetEvent.promptTyped(id: id, token: token)
        let data = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(FleetEvent.self, from: data)
        XCTAssertEqual(decoded, event)
        // Tag is the stable wire string, not derived from the case name.
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(json.contains("\"prompt.typed\""), json)
    }

    func testPromptTypedCarriesSessionIdAndNoProject() {
        let id = UUID()
        let event = FleetEvent.promptTyped(id: id, token: UUID())
        XCTAssertEqual(event.sessionID, id)
        XCTAssertNil(event.projectID)
    }

    func testPromptTypedIsANoOpOnTheSnapshot() {
        var snapshot = FleetSnapshot(projects: [])
        let before = snapshot
        snapshot.apply(.promptTyped(id: UUID(), token: UUID()))
        XCTAssertEqual(snapshot, before, "a typed signal carries no fleet state")
    }
}
```

- [ ] **Step 2: Run it, verify it fails to compile** — `scripts/test-unit.sh`. Expected: compile error, `FleetEvent` has no member `promptTyped`.

- [ ] **Step 3: Add the case + accessor arms** — in `Sources/FleetKit/FleetEvent.swift`, add after the `.promptExpired` case (copy its doc, retarget to "typed into the agent"):

```swift
/// The Mac has TYPED a phone-sent prompt into the agent (queued into the running turn or
/// submitted at an idle box). Like `.promptExpired`, it carries the token and is addressed
/// to one screen's outbox — not fleet state — so the phone can show the prompt as delivered
/// and draw its ghost. Emitted from `SessionStore.flushPromptQueue`'s `onSent`.
case promptTyped(id: UUID, token: UUID)
```

In the same file's `var sessionID: UUID?` switch add `case .promptTyped(let id, _): return id` (beside `.promptExpired`), and in `var projectID: UUID?` ensure it falls into the `return nil` group (add `case .promptTyped` to the nil arm if the switch is exhaustive — match how `.promptExpired` is handled).

- [ ] **Step 4: Add wire coding** — in `Sources/FleetKit/WireCoding.swift`: add `case promptTyped = "prompt.typed"` to `FleetEventTag` (after `.promptExpired`, line ~19); add the encode arm (after `.promptExpired`, line ~99) and decode arm (after `.promptExpired`, line ~160), both identical in shape to `.promptExpired`:

```swift
// encode:
case .promptTyped(let id, let token):
    try c.encode(FleetEventTag.promptTyped, forKey: .t)
    try c.encode(id, forKey: .id)
    try c.encode(token, forKey: .token)
// decode:
case .promptTyped:
    self = .promptTyped(id: try c.decode(UUID.self, forKey: .id),
                        token: try c.decode(UUID.self, forKey: .token))
```

- [ ] **Step 5: Add the no-op snapshot arm** — in `Sources/FleetKit/SnapshotApplication.swift`, add `.promptTyped` to the `.promptExpired` no-op arm (same `case .promptExpired, .promptTyped:` group, or a sibling `case .promptTyped: break` with a one-line comment "no fleet state, like promptExpired").

- [ ] **Step 6: Run tests, verify pass** — `scripts/test-unit.sh`. Expected: PASS, full suite green.

- [ ] **Step 7: Commit** — `git commit -am "feat(wire): FleetEvent.promptTyped — Mac→phone 'typed into agent' signal"`

---

### Task 2: Mac emits `.promptTyped` when it types the prompt

**Files:**
- Modify: `Sources/FlightDeck/SessionStore.swift` — `flushPromptQueue(_:)` `onSent` closure (~3974)
- Test: `Tests/FlightDeckTests/PromptTypedEmitTests.swift`

**Interfaces:**
- Consumes: `FleetEvent.promptTyped` (Task 1); `SessionStore.emit(_:)`; the existing `flushPromptQueue`/`inject`/`AgentTextChannel` path.

- [ ] **Step 1: Write the failing test.** Model it on the existing phone-prompt store tests (see `Tests/FlightDeckTests/PhonePromptQueueTests.swift` for how a `SessionStore` is stood up with a stub `TextInjecting`/`AgentTextChannel` and an emit sink is observed). The test: an idle claude tab with an empty box; call `store.submitPrompt("hi", token: t, to: id)`; drive the injection settle; assert the emit sink received `.promptTyped(id: id, token: t)` exactly once, after the text was submitted.

```swift
// Sketch — match the harness PhonePromptQueueTests uses (stub channel whose submit calls
// settle{ onSent() }, a substituted injectionSettle, and store.eventSink/emit observation):
func testTypingAPhonePromptEmitsPromptTyped() {
    // arrange: store with one idle claude tab `id`, empty-box stub channel, captured events
    // act: store.submitPrompt("hi", token: t, to: id); run the settle
    // assert: captured.contains(.promptTyped(id: id, token: t))
}
```

- [ ] **Step 2: Run it, verify it fails** — `scripts/test-unit.sh`. Expected: FAIL (no `.promptTyped` emitted).

- [ ] **Step 3: Emit in `onSent`.** In `SessionStore.flushPromptQueue(_:)`, inside the `onSent:` closure passed to `inject(...)` (where `promptQueue[id]?.removeFirst()` runs, ~3974), add — using the `head.token` already in scope — `self.emit([.promptTyped(id: id, token: head.token)])`. Place it beside the removal; guard the same way the removal is guarded (only when the head token still matches). Do not touch `submitPrompt` itself.

- [ ] **Step 4: Run tests, verify pass** — `scripts/test-unit.sh`. Expected: PASS.

- [ ] **Step 5: Commit** — `git commit -am "feat: emit promptTyped when the Mac types a phone prompt into the agent"`

---

### Task 3: PromptOutbox `.delivered` state + `deliver(_:)`

**Files:**
- Modify: `Sources/FleetKit/PromptOutbox.swift`
- Test: `Tests/FlightDeckTests/` (or the FleetKit-exercising target) — add `PromptOutboxDeliveredTests.swift`

**Interfaces:**
- Produces: `PromptOutboxEntry.State.delivered`; `mutating func PromptOutbox.deliver(_ token: UUID)`.

- [ ] **Step 1: Write the failing test:**

```swift
import XCTest
@testable import FleetKit

final class PromptOutboxDeliveredTests: XCTestCase {
    func testDeliverMovesAcceptedEntryToDelivered() {
        var outbox = PromptOutbox()
        let t = UUID()
        outbox.add(id: t, text: "hi", alreadyShowing: [])
        outbox.accept(t)
        outbox.deliver(t)
        XCTAssertEqual(outbox.entries.first?.state, .delivered)
    }
    func testDeliverIsIdempotentAndSafeForUnknownToken() {
        var outbox = PromptOutbox()
        outbox.deliver(UUID())                 // no entry — no-op
        let t = UUID(); outbox.add(id: t, text: "hi", alreadyShowing: [])
        outbox.deliver(t); outbox.deliver(t)   // twice — still one delivered entry
        XCTAssertEqual(outbox.entries.filter { $0.state == .delivered }.count, 1)
    }
    func testReconcileDropsADeliveredEntryWhenTheTranscriptHoldsIt() {
        var outbox = PromptOutbox()
        let t = UUID(); outbox.add(id: t, text: "hi", alreadyShowing: [])
        outbox.deliver(t)
        let item = TimelineItem(id: "0#0", kind: .userTurn, body: .init(text: "hi"))
        outbox.reconcile(with: [item])
        XCTAssertTrue(outbox.entries.isEmpty)
    }
}
```
(Match the real `TimelineItem` initializer/`body` shape used elsewhere in tests; adjust the constructor if needed.)

- [ ] **Step 2: Run it, verify it fails** — `scripts/test-unit.sh`. Expected: FAIL (no `.delivered`, no `deliver`).

- [ ] **Step 3: Implement.** In `PromptOutbox.swift`: add `case delivered` to `PromptOutboxEntry.State` (update the "three states and no fourth" doc — the Mac can now report the typed moment via `.promptTyped`); add:

```swift
/// The Mac reported (via `FleetEvent.promptTyped`) that it typed this prompt into the
/// agent. Idempotent: a missing or already-removed entry is a no-op — covers replay and
/// duplicate signals. `reconcile` still retires it when the transcript catches up.
public mutating func deliver(_ id: UUID) {
    guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
    entries[index].state = .delivered
}
```
Confirm `reconcile(with:)` retires entries regardless of state (it matches on text + witnessed, not state) — no change needed; the tests above prove it.

- [ ] **Step 4: Run tests, verify pass** — `scripts/test-unit.sh`. Expected: PASS.

- [ ] **Step 5: Commit** — `git commit -am "feat(outbox): add .delivered state + deliver(_:)"`

---

### Task 4: Phone routing — `FleetModel.onEvent` + `SessionTimelineModel.promptTyped`

**Files:**
- Modify: `Sources/FlightDeckMobile/FleetModel.swift` (~631, the `connector.onEvent` switch)
- Modify: `Sources/FlightDeckMobile/SessionTimelineModel.swift` (~1079, beside `promptExpired(_:)`)
- Test: `Tests/FlightDeckMobileTests/` — add `SessionTimelineDeliveredTests.swift`

**Interfaces:**
- Consumes: `FleetEvent.promptTyped` (Task 1); `PromptOutbox.deliver` (Task 3).
- Produces: `SessionTimelineModel.promptTyped(_ token: UUID)`.

- [ ] **Step 1: Write the failing test** — model on the existing test for `promptExpired` if present; otherwise: a `SessionTimelineModel` with an outbox entry `t` in `.accepted`; call `model.promptTyped(t)`; assert its outbox entry is `.delivered`.

- [ ] **Step 2: Run it, verify it fails** — `scripts/test-ios.sh`. Expected: FAIL.

- [ ] **Step 3: Implement.** In `SessionTimelineModel.swift`, beside `func promptExpired(_ token: UUID)`:

```swift
func promptTyped(_ token: UUID) { outbox.deliver(token) }
```
In `FleetModel.swift`'s `connector.onEvent` handler, add a second `guard case`/`case` arm beside the `.promptExpired` one:

```swift
if case .promptTyped(let id, let token) = event {
    self?.timelineModels[id]?.promptTyped(token); return
}
```
(Match the exact structure of the existing `.promptExpired` arm at ~631 — it uses `MainActor.assumeIsolated { guard case ... }`.)

- [ ] **Step 4: Run tests, verify pass** — `scripts/test-ios.sh`. Expected: PASS.

- [ ] **Step 5: Commit** — `git commit -am "feat(mobile): route promptTyped → outbox.deliver"`

---

### Task 5: Inline transcript ghost + failure-only outbox row

**Files:**
- Modify: `Sources/FlightDeckMobile/SessionTimelineScreen.swift` (`entries` computed var ~421; the `Entry` type ~537; `entryRow`)
- Modify: `Sources/FlightDeckMobile/PromptComposer.swift` (`body` ~109 / `outboxRow` — render only `.failed`)
- Test: `Tests/FlightDeckMobileTests/` — add `TranscriptGhostTests.swift`

**Interfaces:**
- Consumes: `PromptOutbox` entries in `.delivered` (Task 3); `SessionTimelineModel`.

- [ ] **Step 1: Write the failing test.** Make `entries` (or a testable pure helper it delegates to, e.g. `static func entries(from feedItems:, delivered:) -> [Entry]`) include a ghost for each delivered outbox entry, id `"ghost:<token>"`, appended after the feed items; and exclude it once the entry is gone (reconciled). Assert:

```swift
func testDeliveredOutboxEntryBecomesATrailingGhost() {
    let t = UUID()
    let feed = [TimelineItem(id: "0#0", kind: .userTurn, body: .init(text: "old"))]
    let delivered = [PromptOutboxEntry(id: t, text: "hi", state: .delivered)]
    let entries = SessionTimelineScreen.entries(fromFeed: feed, delivered: delivered)
    XCTAssertEqual(entries.last?.id, "ghost:\(t.uuidString)")
    XCTAssertEqual(entries.dropLast().map(\.id), ["0#0"])
}
func testNoGhostWithoutADeliveredEntry() {
    let feed = [TimelineItem(id: "0#0", kind: .userTurn, body: .init(text: "old"))]
    let entries = SessionTimelineScreen.entries(fromFeed: feed, delivered: [])
    XCTAssertEqual(entries.map(\.id), ["0#0"])
}
```
(Adjust to the real `Entry`/`TimelineItem`/`PromptOutboxEntry` initializers.)

- [ ] **Step 2: Run it, verify it fails** — `scripts/test-ios.sh`. Expected: FAIL.

- [ ] **Step 3: Implement.** Refactor `entries` to delegate to a pure static helper `entries(fromFeed:delivered:)` that maps `feedItems` to `Entry`s then appends one ghost `Entry` per delivered outbox entry (id `"ghost:\(token.uuidString)"`, in send order, at the end). The call site passes `model.feed.items` and `model.outbox.entries.filter { $0.state == .delivered }`. Give `Entry` a way to carry a ghost (e.g. an associated `TimelineItem?` plus a ghost flag, or a synthetic `TimelineItem`) and render it in `entryRow` with a distinct pending style + copy ("Queued to your agent"). Do NOT feed the ghost through `model.feed`/`TimelineFeed`. In `PromptComposer.swift`, change the outbox rendering to iterate only `entries.filter { if case .failed = $0.state { true } else { false } }` (delivered → ghost; sending/accepted → no row).

- [ ] **Step 4: Run tests, verify pass** — `scripts/test-ios.sh`. Expected: PASS.

- [ ] **Step 5: Commit** — `git commit -am "feat(mobile): inline transcript ghost for delivered prompts; failures-only outbox row"`

---

### Task 6: Integration — loopback asserts `promptTyped` follows the ack

**Files:**
- Modify/add: `Tests/FlightDeckTests/` — extend `TimelineLoopbackTests` or add `PromptDeliveredLoopbackTests.swift` modeled on it + `FleetTestHarness`.

- [ ] **Step 1: Write the failing test.** Using `FleetTestHarness` + a real `FleetClient` over `service.loopbackEndpoint()` (see `TimelineLoopbackTests`), with the store set up so a tab can accept a prompt: send `FleetCommand.prompt(id:token:text:)`, await the `ack`, then await a `.promptTyped(id:, token:)` event for the same token via `client.onEvent`. (The harness silences `promptLifecycleSink`; make the tab injectable so `onSent` fires — reuse whatever `PhonePromptQueueTests`/`AbortPromptLoopbackTests` do to make injection succeed.)

- [ ] **Step 2: Run it, verify it fails** — `scripts/test-unit.sh` (before Task 2 it would fail; here it verifies the whole wire). Expected: PASS once Tasks 1–3 are in (this task only adds the test). If it fails, the wire is broken — fix before proceeding.

- [ ] **Step 3: Commit** — `git commit -am "test: loopback asserts promptTyped follows the prompt ack"`

---

### Task 7: Remove the temporary DEBUG diagnostic hooks

**Files:**
- Modify: `Sources/FlightDeck/SessionStore.swift`

- [ ] **Step 1: Remove** the `#if DEBUG` hooks added during the investigation and their init calls: `startViewportDiagnosticsIfRequested()`, `startPhonePromptSimulationIfRequested()`, `startLoopbackPromptTestIfRequested()`, the `loopbackTestService`/`loopbackTestClient` stored properties, and the three calls in the convenience `init`'s `#if DEBUG` block. **Keep** the permanent instrumentation: `PromptLifecycleRecord.typing`, `logPromptTyping`, `promptTypingComposerState`, and the `flushPromptQueue` "attempt"/"inject=" logging.

- [ ] **Step 2: Run tests, verify pass** — `scripts/test-unit.sh`. Expected: PASS.

- [ ] **Step 3: Commit** — `git commit -am "chore: remove temporary phone-prompt investigation DEBUG hooks"`

---

## Verification (end-to-end)

- `scripts/test-unit.sh` green (Tasks 1,2,3,6,7) and `scripts/test-ios.sh` green (Tasks 4,5). Budget ~8 min each; foreground.
- Manual (after shipping — see below): from the phone, send a prompt to a busy Claude tab. Expected: a "Queued to your agent" ghost appears in the transcript within a moment (not a "Waiting for your Mac to type this" row), and it is replaced by the real message when the turn ends. The permanent `flight-deck-prompt.log` shows `typing stage=attempt … inject=true` and the phone receives `promptTyped`.

## Ship (after the plan is implemented + reviewed)

End-to-end requires BOTH:
- **Mac:** a new Release build swapped into `/Applications` via `scripts/swap-release.sh` — this kills/restarts all ~42 fleet tabs, so run it at a quiet time of Nate's choosing, detached/sentinel-guarded (see memory `swapping-kills-this-session`). Verify the installed bundle carries the change.
- **Phone:** a new build via `scripts/deploy-phone.sh` — it exits 0 even on failure, so verify the install actually landed (see memory `deploy-phone-exits-zero-on-failure`).
The phone alone cannot show the ghost; it needs the Mac's `promptTyped` signal.
