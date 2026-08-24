# State Integrity L1 — Identity-Routed Events — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make it structurally impossible for one agent event to write more than one tab's state, and stop a failed resume from renaming a conversation.

**Architecture:** Today both runtimes key their attachments by `conversationID`, so a second tab attaching to a conversation replaces the first's; `SessionStore` compensates with a value-matching fan-out (`tabs(following:)`) that is the only many-tab title writer in the codebase. This plan restores subscriber identity to the runtimes — one `Source` per conversation holding a *list* of subscribers, each carrying its own tab id — and routes events straight to the subscribing tab. Shared subscriber mechanics live in one type so a third agent cannot copy the defect.

**Tech Stack:** Swift 6 / SwiftUI, XCTest (app-hosted bundle), xcodegen (`project.yml`).

**Spec:** `docs/superpowers/specs/2026-08-24-state-integrity-and-instance-isolation-design.md` (§0, §2, §4.2)

## Global Constraints

- **Agent-agnostic.** No change may branch on `AgentID` outside an adapter/runtime implementation. Every runtime-level test runs against both `ClaudeRuntime` and `CodexRuntime`.
- **Suite green at every commit.** Tasks 2–4 add the new API alongside the old; the old API is removed only in Task 6.
- **Test command:** `./scripts/test-unit.sh` (runs the whole bundle; no filter flag). To read one result: `./scripts/test-unit.sh 2>&1 | rg <TestName>`.
- **Never run `./scripts/smoke.sh` in a loop** — it steals focus for ~40s per run.
- **Do not launch or swap a build into `/Applications`** during this work.

## What actually fails today (read before Task 5)

The incident cannot be reproduced from the outside: `SessionStore.attachments` is in-memory, and we never determined what put 21 entries on one conversation id. So:

- **Task 3/4's `testTwoTabsOnOneConversationBothReceive` genuinely fails today** — the second `attach` calls `attachments[id]?.watcher?.stop()` and replaces the entry. This is the real regression gate.
- **Task 5's store-level single-delivery test passes today.** With distinct conversations `tabs(following:)` returns one tab. It is a *guard against reintroduction*, not a reproduction. Do not describe it as reproducing the bug.

---

### Task 1: A failed resume must not rename a conversation

Spec §4.2. Independent of the rest and the most urgent: while stored titles are wrong, every launch re-stamps them into transcripts.

**Files:**
- Modify: `Sources/FlightDeck/ClaudeSession.swift:140-149`
- Modify: `Sources/FlightDeck/Agents/ClaudeAdapter.swift:57-61`
- Test: `Tests/FlightDeckTests/ClaudeSessionTests.swift:113-118,151-155`
- Test: `Tests/FlightDeckTests/SessionPersistenceTests.swift:148`
- Test: `Tests/FlightDeckTests/ReopenClosedSessionTests.swift:67`

**Interfaces:**
- Produces: `ClaudeSession.resumeCommand(sessionID:flags:) -> String` — the `title:` parameter is **removed**, since the fallback no longer names anything. `launchCommand(sessionID:title:flags:)` is unchanged.

- [ ] **Step 1: Write the failing test**

In `Tests/FlightDeckTests/ClaudeSessionTests.swift`:

```swift
func testResumeFallbackDoesNotNameTheSession() {
    let command = ClaudeSession.resumeCommand(sessionID: fixedID)
    XCTAssertFalse(
        command.contains("--name"),
        "a failed --resume must not rename a conversation: this is what stamped 24 transcripts on 2026-08-23"
    )
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `./scripts/test-unit.sh 2>&1 | rg "resumeFallbackDoesNotName|error:"`
Expected: a compile error — `resumeCommand` still requires `title:`.

- [ ] **Step 3: Change the implementation**

`Sources/FlightDeck/ClaudeSession.swift`, replacing the body at 140-149:

```swift
    /// The command for a session restored from a previous app launch. Reattaches to the
    /// existing conversation, falling back to a fresh session with the same id when the
    /// transcript has been deleted or pruned (`--resume` exits 1 in that case).
    ///
    /// **The fallback deliberately does not pass `--name`.** A failed resume is a failure
    /// path, and no failure path may rename a conversation: on 2026-08-23 this branch
    /// stamped a wrong stored title into 24 transcripts in three seconds, and re-stamped
    /// them on every launch afterwards. The fresh session is left to name itself, and that
    /// name flows back through the tab's own `.title` event like any other rename.
    ///
    /// Flags are applied to **both** branches: the fallback is a real session launch, and
    /// leaving it unconfigured would silently drop every preference the moment a
    /// transcript is pruned.
    static func resumeCommand(
        sessionID: UUID, flags: FlagSet = FlagSet()
    ) -> String {
        let id = sessionID.uuidString.lowercased()
        let tail = ClaudeFlagSerializer.serialize(launchable(flags))
        let suffix = tail.isEmpty ? "" : " \(tail)"
        return "claude --resume \(id)\(suffix) || claude --session-id \(id)\(suffix)\n"
    }
```

`Sources/FlightDeck/Agents/ClaudeAdapter.swift`, replacing 57-61:

```swift
    func resumeCommand(_ binding: AgentBinding, _ session: Session, _ options: AgentOptions) -> String {
        ClaudeSession.resumeCommand(sessionID: binding.conversationID, flags: flags(options))
    }
```

- [ ] **Step 4: Update the four tests that assert the old string**

`ClaudeSessionTests.swift:113-118` and `:151-155` — drop `title:` and the `--name '…'` tail:

```swift
        XCTAssertEqual(
            ClaudeSession.resumeCommand(sessionID: sid),
            "claude --resume \(id) || claude --session-id \(id)\n"
        )
```

```swift
    func testResumeCommandWithNoFlagsIsUnchanged() {
        let command = ClaudeSession.resumeCommand(sessionID: fixedID)
        let id = "4f3a0000-0000-0000-0000-000000000001"
        XCTAssertEqual(command, "claude --resume \(id) || claude --session-id \(id)\n")
    }
```

`ClaudeSessionTests.swift:142-148` keeps asserting flags appear twice; drop only `title:`. `SessionPersistenceTests.swift:148` and `ReopenClosedSessionTests.swift:67` — drop the `title:` argument at each call site. Do not change what they assert otherwise.

- [ ] **Step 5: Run the suite**

Run: `./scripts/test-unit.sh`
Expected: PASS, no compile errors.

- [ ] **Step 6: Commit**

```bash
git add Sources/FlightDeck/ClaudeSession.swift Sources/FlightDeck/Agents/ClaudeAdapter.swift Tests/FlightDeckTests/ClaudeSessionTests.swift Tests/FlightDeckTests/SessionPersistenceTests.swift Tests/FlightDeckTests/ReopenClosedSessionTests.swift
git commit -m "fix: stop a failed resume renaming the conversation it failed to resume"
```

---

### Task 2: `AttachmentToken` and the shared subscriber list

**Files:**
- Create: `Sources/FlightDeck/Agents/AttachmentToken.swift`
- Test: `Tests/FlightDeckTests/SubscriberListTests.swift`

**Interfaces:**
- Produces: `AttachmentToken` (`Hashable, Sendable`, `init(conversationID: UUID, tab: UUID)`, properties `conversationID`, `tab`) and `@MainActor final class SubscriberList` with `isEmpty: Bool`, `add(_:_:)`, `@discardableResult remove(_:) -> Bool`, `emit(_:)`. Tasks 3, 4 and 5 all depend on these exact names.

- [ ] **Step 1: Write the failing test**

Create `Tests/FlightDeckTests/SubscriberListTests.swift`:

```swift
import XCTest
@testable import FlightDeck

@MainActor
final class SubscriberListTests: XCTestCase {
    private func token(_ conversation: UUID, _ tab: UUID) -> AttachmentToken {
        AttachmentToken(conversationID: conversation, tab: tab)
    }

    func testEmitReachesEverySubscriber() {
        let conversation = UUID()
        let list = SubscriberList()
        var a: [AgentEvent] = []
        var b: [AgentEvent] = []
        list.add(token(conversation, UUID())) { a.append($0) }
        list.add(token(conversation, UUID())) { b.append($0) }

        list.emit(.title("shared"))

        XCTAssertEqual(a, [.title("shared")])
        XCTAssertEqual(b, [.title("shared")], "a second subscriber must not replace the first")
    }

    func testRemovingOneSubscriberLeavesTheOther() {
        let conversation = UUID()
        let list = SubscriberList()
        let first = token(conversation, UUID())
        var a: [AgentEvent] = []
        var b: [AgentEvent] = []
        list.add(first) { a.append($0) }
        list.add(token(conversation, UUID())) { b.append($0) }

        XCTAssertTrue(list.remove(first))
        list.emit(.title("after"))

        XCTAssertTrue(a.isEmpty)
        XCTAssertEqual(b, [.title("after")])
        XCTAssertFalse(list.isEmpty)
    }

    func testRemovingTheLastSubscriberEmptiesTheList() {
        let only = token(UUID(), UUID())
        let list = SubscriberList()
        list.add(only) { _ in }
        XCTAssertTrue(list.remove(only))
        XCTAssertTrue(list.isEmpty)
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `./scripts/test-unit.sh 2>&1 | rg "SubscriberList|error:"`
Expected: compile error — `AttachmentToken` and `SubscriberList` do not exist.

- [ ] **Step 3: Write the implementation**

Create `Sources/FlightDeck/Agents/AttachmentToken.swift`:

```swift
import Foundation

/// One tab's subscription to one conversation's event source.
///
/// Identity, not a value match. The 2026-08-23 rename spread because the store decided who
/// an event belonged to by scanning a dictionary for entries whose `conversationID` equalled
/// the event's — so a single wrong entry widened one event's blast radius to every tab on the
/// account. A token is handed out by the runtime at `attach` and handed back at `detach`, so
/// an event can only ever reach a tab that asked for it.
struct AttachmentToken: Hashable, Sendable {
    let conversationID: UUID
    let tab: UUID
}

/// The subscribers on one conversation's source.
///
/// Shared by every `AgentRuntime` rather than reimplemented per agent: both runtimes
/// previously kept `[conversationID: Attachment]`, so a second tab attaching to a
/// conversation *replaced* the first — stopping its watcher and orphaning its closure. Any
/// future agent that copied that shape would reintroduce the defect, so the mechanics live
/// here and the runtimes hold one of these per source.
@MainActor
final class SubscriberList {
    private var handlers: [AttachmentToken: (AgentEvent) -> Void] = [:]

    var isEmpty: Bool { handlers.isEmpty }

    func add(_ token: AttachmentToken, _ onEvent: @escaping (AgentEvent) -> Void) {
        handlers[token] = onEvent
    }

    @discardableResult
    func remove(_ token: AttachmentToken) -> Bool {
        handlers.removeValue(forKey: token) != nil
    }

    func emit(_ event: AgentEvent) {
        for handler in handlers.values { handler(event) }
    }
}
```

- [ ] **Step 4: Add the file to the target and run the tests**

`project.yml` builds `Sources/FlightDeck` by directory, so no project edit is needed. Run: `./scripts/test-unit.sh 2>&1 | rg "SubscriberList"`
Expected: three PASS lines.

- [ ] **Step 5: Commit**

```bash
git add Sources/FlightDeck/Agents/AttachmentToken.swift Tests/FlightDeckTests/SubscriberListTests.swift
git commit -m "feat: add AttachmentToken and the shared runtime subscriber list"
```

---

### Task 3: `ClaudeRuntime` gains token-based attach

Additive — the existing `attach(_:onEvent:)`/`detach(_:)` stay and delegate, so the suite stays green.

**Files:**
- Modify: `Sources/FlightDeck/Agents/ClaudeRuntime.swift` (whole file)
- Test: `Tests/FlightDeckTests/ClaudeRuntimeTests.swift`

**Interfaces:**
- Consumes: `AttachmentToken`, `SubscriberList` (Task 2).
- Produces: `ClaudeRuntime.attach(_ binding: AgentBinding, for tab: UUID, onEvent: @escaping (AgentEvent) -> Void) -> AttachmentToken` and `ClaudeRuntime.detach(_ token: AttachmentToken)`.

- [ ] **Step 1: Write the failing test**

Append to `Tests/FlightDeckTests/ClaudeRuntimeTests.swift`:

```swift
    func testTwoTabsOnOneConversationBothReceive() throws {
        let id = UUID()
        let url = dir.appendingPathComponent("shared.jsonl")
        let runtime = ClaudeRuntime()

        var first: [AgentEvent] = []
        var second: [AgentEvent] = []
        let binding = AgentBinding(conversationID: id, transcriptURL: url)
        _ = runtime.attach(binding, for: UUID()) { first.append($0) }
        _ = runtime.attach(binding, for: UUID()) { second.append($0) }
        runtime.drainForTesting()

        try titleLine("renamed", id).write(to: url, atomically: true, encoding: .utf8)
        runtime.drainForTesting()

        XCTAssertEqual(first, [.title("renamed")], "the second attach must not stop the first tab's watcher")
        XCTAssertEqual(second, [.title("renamed")])
    }

    func testDetachingOneOfTwoLeavesTheOtherWatching() throws {
        let id = UUID()
        let url = dir.appendingPathComponent("shared.jsonl")
        let runtime = ClaudeRuntime()

        var first: [AgentEvent] = []
        var second: [AgentEvent] = []
        let binding = AgentBinding(conversationID: id, transcriptURL: url)
        let a = runtime.attach(binding, for: UUID()) { first.append($0) }
        _ = runtime.attach(binding, for: UUID()) { second.append($0) }
        runtime.drainForTesting()

        runtime.detach(a)
        try titleLine("after", id).write(to: url, atomically: true, encoding: .utf8)
        runtime.drainForTesting()

        XCTAssertTrue(first.isEmpty, "a detached subscriber must receive nothing")
        XCTAssertEqual(second, [.title("after")], "the surviving subscriber must keep its watcher")
    }
```

- [ ] **Step 2: Run to verify it fails**

Run: `./scripts/test-unit.sh 2>&1 | rg "TwoTabsOnOneConversation|error:"`
Expected: compile error — no `attach(_:for:onEvent:)`.

- [ ] **Step 3: Rewrite `ClaudeRuntime`**

Replace the body of `Sources/FlightDeck/Agents/ClaudeRuntime.swift` between `final class ClaudeRuntime` and `drainForTesting`:

```swift
    /// One conversation's event source: the single watcher, plus everyone listening to it.
    private struct Source {
        let subscribers: SubscriberList
        let watcher: TranscriptWatcher?
    }

    private var sources: [UUID: Source] = [:]
    private let clock: WatchClock?

    init(clock: WatchClock? = nil) {
        self.clock = clock
    }

    /// Subscribes `tab` to `binding`'s conversation, starting a watcher if this is the first
    /// subscriber. A second tab on the same conversation joins the existing source rather
    /// than replacing it — which is what the old `attachments[id] = …` did, stopping the
    /// first tab's watcher and leaving the store to compensate with a value-matched fan-out.
    func attach(
        _ binding: AgentBinding, for tab: UUID, onEvent: @escaping (AgentEvent) -> Void
    ) -> AttachmentToken {
        let id = binding.conversationID
        let token = AttachmentToken(conversationID: id, tab: tab)

        if let existing = sources[id] {
            existing.subscribers.add(token, onEvent)
            return token
        }

        let subscribers = SubscriberList()
        subscribers.add(token, onEvent)

        var watcher: TranscriptWatcher?
        if let url = binding.transcriptURL {
            watcher = TranscriptWatcher(
                sessionID: id,
                url: url,
                clock: clock,
                onTitle: { subscribers.emit(.title($0)) },
                onSubagentCount: { subscribers.emit(.subagentCount($0)) }
            )
            watcher?.start()
        }
        sources[id] = Source(subscribers: subscribers, watcher: watcher)
        return token
    }

    /// Drops one subscriber, and the watcher only when it was the last.
    ///
    /// Stopped explicitly rather than left to the released `Source`: it survives its owner by
    /// its registration on the shared `WatchClock`, and although that registration is weak
    /// and self-prunes, an invariant that holds only because of a retention detail two files
    /// away is not one to lean on.
    func detach(_ token: AttachmentToken) {
        guard let source = sources[token.conversationID] else { return }
        source.subscribers.remove(token)
        guard source.subscribers.isEmpty else { return }
        source.watcher?.stop()
        sources[token.conversationID] = nil
    }

    /// Deprecated conversation-keyed API, kept only until `SessionStore` moves to tokens
    /// (Task 5) so the suite stays green mid-migration. Removed in Task 6.
    func attach(_ binding: AgentBinding, onEvent: @escaping (AgentEvent) -> Void) {
        _ = attach(binding, for: binding.conversationID, onEvent: onEvent)
    }

    func detach(_ binding: AgentBinding) {
        detach(AttachmentToken(conversationID: binding.conversationID, tab: binding.conversationID))
    }

    /// Fan-out point for the shared status watcher. `SessionStore` owns the one
    /// `SessionStatusWatcher` and hands its output here rather than this type owning a
    /// second one — the registry must be scanned once per tick, not once per tab.
    func ingest(_ entries: [pid_t: ClaudeStatusFile.Entry]) {
        for entry in entries.values {
            sources[entry.sessionID]?.subscribers.emit(.activity(entry.activity))
        }
    }
```

And update `drainForTesting`:

```swift
    /// Test seam mirroring `TranscriptWatcher.drain()`, so runtime tests need no clock.
    func drainForTesting() {
        for source in sources.values { source.watcher?.drain() }
    }
```

- [ ] **Step 4: Run the tests**

Run: `./scripts/test-unit.sh`
Expected: PASS, including the two new tests and every pre-existing `ClaudeRuntimeTests` case.

- [ ] **Step 5: Commit**

```bash
git add Sources/FlightDeck/Agents/ClaudeRuntime.swift Tests/FlightDeckTests/ClaudeRuntimeTests.swift
git commit -m "fix: let two tabs share a claude conversation without replacing each other"
```

---

### Task 4: `CodexRuntime` gains token-based attach

Same change, same defect (`CodexRuntime.swift:46-47`), plus the name-watcher registration at `:49` which replaces per id in the same way.

**Files:**
- Modify: `Sources/FlightDeck/Agents/Codex/CodexRuntime.swift` (whole file)
- Test: `Tests/FlightDeckTests/CodexRuntimeAttachmentTests.swift`

**Interfaces:**
- Consumes: `AttachmentToken`, `SubscriberList` (Task 2).
- Produces: `CodexRuntime.attach(_:for:onEvent:) -> AttachmentToken`, `CodexRuntime.detach(_ token: AttachmentToken)` — signatures identical to Task 3's.

- [ ] **Step 0: Read the existing test file**

Read `Tests/FlightDeckTests/CodexRuntimeAttachmentTests.swift` and `CodexNameWatcherTests.swift`
in full before writing anything. The tests below assume an `indexURL` property and a
`writeIndexEntry(threadID:name:)` helper; the real names in that file may differ. Use whatever
it already has — do not add a parallel fixture.

- [ ] **Step 1: Write the failing test**

Append to `Tests/FlightDeckTests/CodexRuntimeAttachmentTests.swift`, adapted to that file's actual helper names:

```swift
    func testTwoTabsOnOneThreadBothReceiveNameEvents() throws {
        let id = UUID()
        let runtime = CodexRuntime(indexURL: indexURL)

        var first: [AgentEvent] = []
        var second: [AgentEvent] = []
        let binding = AgentBinding(conversationID: id, transcriptURL: nil)
        _ = runtime.attach(binding, for: UUID()) { first.append($0) }
        _ = runtime.attach(binding, for: UUID()) { second.append($0) }

        try writeIndexEntry(threadID: id, name: "renamed")
        runtime.drainForTesting()

        XCTAssertEqual(first, [.title("renamed")], "the second attach must not replace the first's registration")
        XCTAssertEqual(second, [.title("renamed")])
    }

    func testDetachingTheLastSubscriberUnregistersTheThread() throws {
        let id = UUID()
        let runtime = CodexRuntime(indexURL: indexURL)
        var seen: [AgentEvent] = []
        let binding = AgentBinding(conversationID: id, transcriptURL: nil)
        let a = runtime.attach(binding, for: UUID()) { seen.append($0) }
        let b = runtime.attach(binding, for: UUID()) { seen.append($0) }

        runtime.detach(a)
        runtime.detach(b)

        try writeIndexEntry(threadID: id, name: "late")
        runtime.drainForTesting()

        XCTAssertTrue(seen.isEmpty, "no subscriber remains, so nothing may be delivered")
    }
```

If `writeIndexEntry` does not already exist in that file, add it modelled on `CodexNameWatcherTests`' index-writing helper.

- [ ] **Step 2: Run to verify it fails**

Run: `./scripts/test-unit.sh 2>&1 | rg "TwoTabsOnOneThread|error:"`
Expected: compile error — no `attach(_:for:onEvent:)`.

- [ ] **Step 3: Rewrite `CodexRuntime`**

Replace the `Attachment` struct, `attachments`, `attach` and `detach`. **Keep unchanged:** the
type's doc comment, `clock`, `indexURL`, `names`, `init(clock:indexURL:)`, and `nameWatcher()`.

```swift
    private struct Source {
        let subscribers: SubscriberList
        let watcher: CodexRolloutWatcher?
    }

    private var sources: [UUID: Source] = [:]

    func attach(
        _ binding: AgentBinding, for tab: UUID, onEvent: @escaping (AgentEvent) -> Void
    ) -> AttachmentToken {
        let id = binding.conversationID
        let token = AttachmentToken(conversationID: id, tab: tab)

        if let existing = sources[id] {
            existing.subscribers.add(token, onEvent)
            return token
        }

        let subscribers = SubscriberList()
        subscribers.add(token, onEvent)

        var watcher: CodexRolloutWatcher?
        if let url = binding.transcriptURL {
            watcher = CodexRolloutWatcher(url: url, clock: clock) { subscribers.emit($0) }
            watcher?.start()
        }
        sources[id] = Source(subscribers: subscribers, watcher: watcher)

        // Registered once per thread, not once per tab: a tab still has a name even with no
        // rollout to tail, and the list below is what fans that name out to every subscriber.
        nameWatcher().register(id) { subscribers.emit(.title($0)) }
        return token
    }

    func detach(_ token: AttachmentToken) {
        let id = token.conversationID
        guard let source = sources[id] else { return }
        source.subscribers.remove(token)
        guard source.subscribers.isEmpty else { return }

        source.watcher?.stop()
        sources[id] = nil
        names?.unregister(id)
        if names?.isEmpty == true {
            names?.stop()
            names = nil
        }
    }

    /// Deprecated conversation-keyed API, removed in Task 6. See `ClaudeRuntime`.
    func attach(_ binding: AgentBinding, onEvent: @escaping (AgentEvent) -> Void) {
        _ = attach(binding, for: binding.conversationID, onEvent: onEvent)
    }

    func detach(_ binding: AgentBinding) {
        detach(AttachmentToken(conversationID: binding.conversationID, tab: binding.conversationID))
    }
```

And `drainForTesting`:

```swift
    func drainForTesting() {
        for source in sources.values { source.watcher?.drain() }
        names?.drain()
    }
```

- [ ] **Step 4: Run the tests**

Run: `./scripts/test-unit.sh`
Expected: PASS, including every pre-existing codex test.

- [ ] **Step 5: Commit**

```bash
git add Sources/FlightDeck/Agents/Codex/CodexRuntime.swift Tests/FlightDeckTests/CodexRuntimeAttachmentTests.swift
git commit -m "fix: let two tabs share a codex thread without replacing each other"
```

---

### Task 5: `SessionStore` routes by token

**Files:**
- Modify: `Sources/FlightDeck/Agents/AgentRuntime.swift:10-14`
- Modify: `Sources/FlightDeck/SessionStore.swift:162-165` (`TabAttachment`), `:3396-3417` (`startWatching`), `:3419-3424` (`stopWatching`)
- Modify: `Tests/FlightDeckTests/FakeAgentRuntime.swift`
- Test: `Tests/FlightDeckTests/AgentRoutingTests.swift`

**Interfaces:**
- Consumes: `attach(_:for:onEvent:) -> AttachmentToken`, `detach(_ token:)` (Tasks 3, 4).
- Produces: `TabAttachment` gains `let token: AttachmentToken`. `FakeAgentRuntime.emit(_:for conversationID:)` keeps its signature so existing store tests compile unchanged.

- [ ] **Step 0: Read the existing test file**

Read `Tests/FlightDeckTests/AgentRoutingTests.swift` in full. It already builds a `SessionStore`
against `FakeAgentRuntime`; the test below assumes helpers named `makeStoreWithFakeRuntime` and
`allSessionIDsForTesting`, which may not be what they are actually called. Use the file's real
helpers — do not construct a `SessionStore` by hand and do not add a parallel fixture.

- [ ] **Step 1: Write the guard test**

Append to `Tests/FlightDeckTests/AgentRoutingTests.swift`, adapted to that file's actual helpers:

```swift
    /// Guard, not a reproduction. The 2026-08-23 fan-out cannot be reproduced from outside —
    /// `attachments` is in-memory and we never established what corrupted it. This asserts the
    /// property that made the corruption possible is gone: an event delivered on one tab's
    /// subscription changes that tab and no other.
    func testATitleEventChangesOnlyTheSubscribingTab() {
        let (store, runtime) = makeStoreWithFakeRuntime(sessionCount: 3)
        let tabs = store.allSessionIDsForTesting
        let target = tabs[1]
        let before = tabs.map { store.title(of: $0) }

        runtime.emit(.title("only-me"), for: store.pinnedConversationID(of: target)!)

        XCTAssertEqual(store.title(of: target), "only-me")
        for (index, tab) in tabs.enumerated() where tab != target {
            XCTAssertEqual(store.title(of: tab), before[index], "tab \(tab) was not subscribed to that event")
        }
    }
```

If `makeStoreWithFakeRuntime` and `allSessionIDsForTesting` do not exist, add them next to the file's existing seams following the same style; do not invent a new fixture type.

- [ ] **Step 2: Run it**

Run: `./scripts/test-unit.sh 2>&1 | rg "OnlyTheSubscribingTab|error:"`
Expected: PASS (see "What actually fails today"). If it FAILS, stop and report — that would mean the store is already mis-routing and the plan's assumptions need revisiting.

- [ ] **Step 3: Change the protocol**

`Sources/FlightDeck/Agents/AgentRuntime.swift`, replacing lines 10-14 (keep the existing doc comment above):

```swift
@MainActor
protocol AgentRuntime: AnyObject {
    /// Subscribes `tab` to `binding`'s conversation. The returned token is the only way to
    /// unsubscribe, and the only thing that decides who an event reaches — deliberately not
    /// a value match on the conversation id, which is what let one event write 21 tabs.
    func attach(
        _ binding: AgentBinding, for tab: UUID, onEvent: @escaping (AgentEvent) -> Void
    ) -> AttachmentToken
    func detach(_ token: AttachmentToken)
}
```

- [ ] **Step 4: Update `FakeAgentRuntime`**

```swift
@MainActor
final class FakeAgentRuntime: AgentRuntime {
    private var handlers: [AttachmentToken: (AgentEvent) -> Void] = [:]
    private(set) var attached: [UUID] = []
    private(set) var detached: [UUID] = []

    func attach(
        _ binding: AgentBinding, for tab: UUID, onEvent: @escaping (AgentEvent) -> Void
    ) -> AttachmentToken {
        let token = AttachmentToken(conversationID: binding.conversationID, tab: tab)
        handlers[token] = onEvent
        attached.append(binding.conversationID)
        return token
    }

    func detach(_ token: AttachmentToken) {
        handlers[token] = nil
        detached.append(token.conversationID)
    }

    /// Delivers to every subscriber on that conversation, exactly as a real source does.
    func emit(_ event: AgentEvent, for conversationID: UUID) {
        for (token, handler) in handlers where token.conversationID == conversationID {
            handler(event)
        }
    }
}
```

- [ ] **Step 5: Update the store**

`SessionStore.swift:162-165`:

```swift
    private struct TabAttachment {
        let instance: AgentInstance
        let binding: AgentBinding
        let token: AttachmentToken
    }
```

`startWatching`, replacing the recording and attach at `:3403-3417`:

```swift
        // The token is the routing identity: the closure below names its tab directly, so
        // nothing scans `attachments` to decide who an event belongs to. Two tabs following
        // one conversation are two subscribers on one source inside the runtime, which is
        // where that multiplexing now lives.
        let token = runtime(for: instance).attach(binding, for: tabID) { [weak self] event in
            self?.apply(event, to: tabID)
        }
        attachments[tabID] = TabAttachment(instance: instance, binding: binding, token: token)
```

`stopWatching`, replacing `:3419-3424`:

```swift
    /// Drops a tab's subscription. The runtime tears its source down when the last
    /// subscriber leaves, so the store no longer has to ask whether anyone else is following.
    private func stopWatching(_ tabID: UUID) {
        guard let attachment = attachments.removeValue(forKey: tabID) else { return }
        runtime(for: attachment.instance).detach(attachment.token)
    }
```

- [ ] **Step 6: Run the suite**

Run: `./scripts/test-unit.sh`
Expected: PASS. `watchedSessionIDs` and `watchedTranscriptURL(of:)` still read `attachments`, so their tests are unaffected.

- [ ] **Step 7: Commit**

```bash
git add Sources/FlightDeck/Agents/AgentRuntime.swift Sources/FlightDeck/SessionStore.swift Tests/FlightDeckTests/FakeAgentRuntime.swift Tests/FlightDeckTests/AgentRoutingTests.swift
git commit -m "fix: route agent events to the subscribing tab instead of matching by conversation"
```

---

### Task 6: Remove the compensating fan-out and the deprecated API

**Files:**
- Modify: `Sources/FlightDeck/SessionStore.swift:3432-3436` (`tabs(following:)`)
- Modify: `Sources/FlightDeck/Agents/ClaudeRuntime.swift`, `Sources/FlightDeck/Agents/Codex/CodexRuntime.swift` (drop the deprecated overloads added in Tasks 3-4)

- [ ] **Step 1: Migrate the existing runtime tests to the token API**

These call the old API and will stop compiling in Step 2, so they move first. In
`Tests/FlightDeckTests/ClaudeRuntimeTests.swift`: `testAttachForwardsATitleFromTheTranscript`,
`testDetachStopsForwarding`, `testStatusEntriesBecomeActivityEvents`, and any other
`runtime.attach(`/`runtime.detach(` call. The pattern is mechanical — bind the token and pass a
tab id:

```swift
        let binding = AgentBinding(conversationID: id, transcriptURL: url)
        let token = runtime.attach(binding, for: UUID()) { seen.append($0) }
        // …
        runtime.detach(token)
```

Do the same for every `attach(`/`detach(` in `Tests/FlightDeckTests/CodexRuntimeAttachmentTests.swift`
and any other test the next step flags. Assertions are unchanged: these tests keep testing what
they tested.

Run `./scripts/test-unit.sh` and confirm green before deleting anything.

- [ ] **Step 2: Delete the deprecated overloads**

Remove `attach(_:onEvent:)` and `detach(_ binding:)` from both runtimes — the four methods marked "Deprecated conversation-keyed API".

- [ ] **Step 3: Build to find remaining callers**

Run: `./scripts/test-unit.sh 2>&1 | rg "error:"`
Expected: errors only where the old API is still called. `tabs(following:)` should now have exactly one caller left, the `injectRename` closure at `SessionStore.swift:548`, which Task 7 removes. If it has any other caller, stop and report rather than deleting it.

- [ ] **Step 4: Run the suite**

Run: `./scripts/test-unit.sh`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/FlightDeck/Agents/ClaudeRuntime.swift Sources/FlightDeck/Agents/Codex/CodexRuntime.swift Tests/FlightDeckTests/ClaudeRuntimeTests.swift Tests/FlightDeckTests/CodexRuntimeAttachmentTests.swift
git commit -m "refactor: drop the conversation-keyed runtime attach API"
```

---

### Task 7: Delete the dead rename fan-out

Spec §2 "Also in scope". `ClaudeAdapter.rename` is unreachable: `SessionStore.rename` dispatches `.claude` inline at `:2661` and only `.codex` reaches `adapter.rename` at `:2668`.

**Files:**
- Modify: `Sources/FlightDeck/SessionStore.swift:540-556` (the `injectRename` closure), `:3432-3436` (`tabs(following:)`), `:2655-2670` (`rename`'s dispatch comment)
- Modify: `Sources/FlightDeck/Agents/ClaudeAdapter.swift:21-23,63-65`
- Test: `Tests/FlightDeckTests/AgentRoutingTests.swift`

- [ ] **Step 1: Confirm it is dead**

Run: `rg -n "injectRename|\.rename\(" Sources/ Tests/`
Expected: `injectRename` appears only in `ClaudeAdapter` (property + `rename`) and the `SessionStore` closure. If any test asserts `ClaudeAdapter.rename`'s behaviour, convert it to assert `SessionStore.rename` dispatches claude inline instead of deleting the coverage.

- [ ] **Step 2: Delete**

Remove `ClaudeAdapter.injectRename` (`:21-23`) and `ClaudeAdapter.rename` (`:63-65`); `AgentAdapter.rename` keeps its default so codex's override is untouched. Remove the `injectRename:` argument from the `ClaudeAdapter(...)` construction at `SessionStore.swift:540-556`, and delete `tabs(following:)` at `:3432-3436`.

- [ ] **Step 3: Document the remaining asymmetry**

Spec §2 requires the claude-inline/codex-adapter split in `SessionStore.rename` be justified at the call site rather than left as an undocumented branch. Extend the comment above `:2661`:

```swift
        case .claude:
            // Inline, not through `adapter.rename`, and this is the one place an agent
            // branch is deliberate rather than incidental: `AgentAdapter.rename` is `async`,
            // so dispatching claude through it would push `injectPendingRename` into a later
            // run-loop turn — and the injection contract is that `inject` decides *now*
            // whether the bar is busy, deferring only if it is. Codex has no such
            // constraint: its rename is a request and nothing waits on it.
            injectPendingRename(id, name)
```

- [ ] **Step 4: Run the suite**

Run: `./scripts/test-unit.sh`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/FlightDeck/SessionStore.swift Sources/FlightDeck/Agents/ClaudeAdapter.swift Tests/FlightDeckTests/AgentRoutingTests.swift
git commit -m "refactor: delete the unreachable rename fan-out and tabs(following:)"
```

---

## Verification

After Task 7:

- [ ] `./scripts/test-unit.sh` — full suite green.
- [ ] `rg -n "tabs\(following" Sources/` returns nothing.
- [ ] `rg -n "\-\-name" Sources/FlightDeck/ClaudeSession.swift` shows `--name` only in `lockedPrefix`/`launchCommand`, never in `resumeCommand`.
- [ ] `./scripts/smoke.sh` **once** — confirm `sessions.json` (`sessionCounter`) and `preferences.v1` are unchanged afterwards.
- [ ] Manual, on a debug build pointed at a scratch state dir via `-FlightDeckStateDir` (never against the real deck): open two tabs, `/resume` the second onto the first's conversation, rename one, confirm both titles update and no third tab changes.

## Follow-on plans

- **L2** — process/state isolation (spec §3): `StateWorld`, the `flock`, fork-with-empty-deck, killing the legacy defaults fallback.
- **L3** — pin correctness and recovery (spec §4): adapter-mediated lineage, stale-pin detection, validation/backups/quarantine, `scripts/fd-state`.
