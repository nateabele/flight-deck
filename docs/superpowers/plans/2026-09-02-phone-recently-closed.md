# Recently Closed on the phone — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the phone's per-project `+` menu a "Recently Closed" section that reopens a
closed session on the Mac, so a phone-side close has an undo.

**Architecture:** `ClosedSessionHistory` gains addressable reads and a keyed take beside its
existing pop. `SessionStore` grows a second entry point onto the same reopen body ⌘⇧T uses.
One new global request (`session.recentlyClosed`), one new reply frame, one new command
(`session.reopen`) — all following the `newSessionOptions` precedent: a request's answer,
never `FleetSnapshot`.

**Tech Stack:** Swift 6, SwiftUI (iOS 17 target), XCTest. FleetKit is the shared wire module;
`FlightDeck` is macOS-only; `FlightDeckMobile` is iOS-only.

**Spec:** `docs/superpowers/specs/2026-09-02-phone-recently-closed-design.md`

## Global Constraints

- **FleetKit imports Foundation, Network, Security and CryptoKit only.** No AppKit, no
  SwiftUI, no app-module types. `project.yml` enforces this structurally.
- **Nothing new enters `FleetSnapshot`.** The history is not rebuildable from fleet events, so
  a snapshot carrying it would fail `FleetReplicator`'s drift assertion.
- **No account id and no account home path may reach an encoded frame.**
  `FleetAccountEmissionTests` guards this class of leak.
- **Two test targets.** `scripts/test-unit.sh` (macOS) does **not** cover
  `Sources/FlightDeckMobile`; `scripts/test-ios.sh` does. Tasks 1–5 run the first, Task 6 runs
  both.
- **New `ServerFrame.Tag` values must be undotted.** `FleetEventTag`'s values are all dotted
  and the decoder tries frame tags first; a dotted frame tag would collide.

---

### Task 1: `ClosedSessionHistory` becomes addressable

**Files:**
- Modify: `Sources/FlightDeck/ClosedSessionHistory.swift`
- Test: `Tests/FlightDeckTests/ClosedSessionHistoryTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `ClosedSessionHistory.sessionEntries: [ClosedSession]` (most recent first,
  top-level `.session` entries only) and
  `ClosedSessionHistory.takeSession(id: UUID) -> ClosedSession?`.

- [ ] **Step 1: Write the failing tests**

Append to `Tests/FlightDeckTests/ClosedSessionHistoryTests.swift`, inside the existing class:

```swift
    /// The menu reads most-recent-first, the opposite of the array's push order.
    func testSessionEntriesComeBackMostRecentFirst() {
        var history = ClosedSessionHistory()
        history.record(.session(closed("one")))
        history.record(.session(closed("two")))

        XCTAssertEqual(history.sessionEntries.map(\.session.title), ["two", "one"])
    }

    /// A project's children are not separately offerable: taking one would leave the project
    /// entry half-consumed, and reopening the project afterwards would reinsert a tab that is
    /// already open.
    func testSessionEntriesSkipsSessionsNestedInAClosedProject() {
        var history = ClosedSessionHistory()
        history.record(.session(closed("loose")))
        history.record(.project(ClosedSessionHistory.ClosedProject(
            path: "/w/a", isCollapsed: false, indexInSidebar: 0,
            sessions: [closed("nested", at: 0)]
        )))

        XCTAssertEqual(history.sessionEntries.map(\.session.title), ["loose"])
    }

    func testTakingASessionByIDRemovesOnlyThatEntry() {
        var history = ClosedSessionHistory()
        let first = closed("one")
        let middle = closed("two")
        let last = closed("three")
        history.record(.session(first))
        history.record(.session(middle))
        history.record(.session(last))

        XCTAssertEqual(history.takeSession(id: middle.session.id), middle)
        XCTAssertEqual(history.sessionEntries.map(\.session.title), ["three", "one"])
        // ⌘⇧T goes on popping whatever is now on top, which is the entry above the hole.
        XCTAssertEqual(history.takeLast(), .session(last))
    }

    func testTakingAnUnknownOrNestedSessionYieldsNothing() {
        var history = ClosedSessionHistory()
        let nested = closed("nested", at: 0)
        history.record(.project(ClosedSessionHistory.ClosedProject(
            path: "/w/a", isCollapsed: false, indexInSidebar: 0, sessions: [nested]
        )))

        XCTAssertNil(history.takeSession(id: nested.session.id))
        XCTAssertNil(history.takeSession(id: UUID()))
        XCTAssertFalse(history.isEmpty, "a failed take must not consume the project entry")
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `scripts/test-unit.sh -only-testing:FlightDeckTests/ClosedSessionHistoryTests`
Expected: FAIL — `value of type 'ClosedSessionHistory' has no member 'sessionEntries'`.

- [ ] **Step 3: Implement**

In `Sources/FlightDeck/ClosedSessionHistory.swift`, after `takeLast()`:

```swift
    /// The top-level closed sessions, most recent first — what a menu lists.
    ///
    /// **Top-level only.** A `ClosedProject`'s children are deliberately absent: offering one
    /// on its own would let a reopen consume half a project entry, and the later ⌘⇧T that
    /// reopened the project would try to reinsert a tab that is already open. A project comes
    /// back whole or not at all, which is the promise `record(.project(_:))` makes.
    ///
    /// Reversed rather than stored reversed, because `record` and `takeLast` both want the
    /// newest at the end and they are the hot path.
    var sessionEntries: [ClosedSession] {
        entries.reversed().compactMap { entry in
            guard case .session(let closed) = entry else { return nil }
            return closed
        }
    }

    /// Removes and returns the top-level `.session` entry for `id`, or nil when there is none.
    ///
    /// **Removal is forced, not a policy.** `SessionStore.reinsertClosed` rebuilds the tab from
    /// the recorded `Session` value, reusing its `id` — that is what makes it resume the real
    /// conversation. Leaving the entry behind would let a later ⌘⇧T insert a second tab with
    /// the same UUID, and `locate(id)` would then find one of two.
    ///
    /// Removes from the middle. `takeLast` goes on popping whatever is left on top.
    mutating func takeSession(id: UUID) -> ClosedSession? {
        let found = entries.firstIndex { entry in
            guard case .session(let closed) = entry else { return false }
            return closed.session.id == id
        }
        guard let found, case .session(let closed) = entries.remove(at: found) else { return nil }
        return closed
    }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `scripts/test-unit.sh -only-testing:FlightDeckTests/ClosedSessionHistoryTests`
Expected: PASS, all eight tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/FlightDeck/ClosedSessionHistory.swift Tests/FlightDeckTests/ClosedSessionHistoryTests.swift
git commit -m "feat: let the reopen stack be read and taken from by id"
```

---

### Task 2: `SessionStore.reopenClosedSession(id:)`

**Files:**
- Modify: `Sources/FlightDeck/SessionStore.swift` (`reopenLastClosed` at ~2699)
- Test: `Tests/FlightDeckTests/ReopenClosedSessionTests.swift`

**Interfaces:**
- Consumes: `ClosedSessionHistory.sessionEntries`, `ClosedSessionHistory.takeSession(id:)`.
- Produces: `SessionStore.reopenClosedSession(id: UUID, directoryExists: (String) -> Bool)` and
  `SessionStore.recentlyClosedSessions: [ClosedSessionHistory.ClosedSession]`.

- [ ] **Step 1: Write the failing tests**

Append to `Tests/FlightDeckTests/ReopenClosedSessionTests.swift`. Match the fixture style
already in that file for building a store with projects and sessions — read it first and reuse
its helpers rather than inventing new ones.

```swift
    /// The phone's reopen is ⌘⇧T aimed at one entry, and must land the tab in the same place.
    @MainActor
    func testReopeningByIDRebuildsTheTabAtItsRecordedIndex() {
        let store = makeStore(projects: ["/w/a"], sessionsPerProject: 3)
        let target = store.repos[0].sessions[1].id

        store.closeSession(target)
        store.reopenClosedSession(id: target, directoryExists: { _ in true })

        XCTAssertEqual(store.repos[0].sessions.count, 3)
        XCTAssertEqual(store.repos[0].sessions[1].id, target, "back among its siblings")
        XCTAssertEqual(store.selectedSessionID, target)
    }

    /// The consumed entry must not still be on the stack, or ⌘⇧T would insert a duplicate id.
    @MainActor
    func testReopeningByIDConsumesTheEntrySoCommandShiftTPopsTheNextOne() {
        let store = makeStore(projects: ["/w/a"], sessionsPerProject: 3)
        let older = store.repos[0].sessions[0].id
        let newer = store.repos[0].sessions[1].id

        store.closeSession(older)
        store.closeSession(newer)
        // Reach past the top of the stack, which is what a menu does and ⌘⇧T cannot.
        store.reopenClosedSession(id: older, directoryExists: { _ in true })
        store.reopenLastClosed(directoryExists: { _ in true })

        XCTAssertEqual(store.repos[0].sessions.count, 3)
        XCTAssertEqual(Set(store.repos[0].sessions.map(\.id)).count, 3, "no duplicate tab ids")
        XCTAssertTrue(store.recentlyClosedSessions.isEmpty)
    }

    @MainActor
    func testReopeningAnUnknownIDDoesNothing() {
        let store = makeStore(projects: ["/w/a"], sessionsPerProject: 2)
        let before = store.repos[0].sessions.map(\.id)

        store.reopenClosedSession(id: UUID(), directoryExists: { _ in true })

        XCTAssertEqual(store.repos[0].sessions.map(\.id), before)
    }

    /// A tab reopened into a collapsed project would come back invisible — `SidebarRow.rows`
    /// renders only the header for a collapsed repo. Same rule `reopenLastClosed` follows.
    @MainActor
    func testReopeningByIDUncollapsesItsProject() {
        let store = makeStore(projects: ["/w/a"], sessionsPerProject: 2)
        let target = store.repos[0].sessions[0].id

        store.closeSession(target)
        store.setCollapsed(true, forProjectAt: store.repos[0].id)
        store.reopenClosedSession(id: target, directoryExists: { _ in true })

        XCTAssertFalse(store.repos[0].isCollapsed)
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `scripts/test-unit.sh -only-testing:FlightDeckTests/ReopenClosedSessionTests`
Expected: FAIL — `value of type 'SessionStore' has no member 'reopenClosedSession'`.

- [ ] **Step 3: Extract the shared body and add the new entry point**

In `Sources/FlightDeck/SessionStore.swift`, replace the `.session` case body inside
`reopenLastClosed` with a call to a new helper, and add the helper plus the new entry point
directly below `reopenLastClosed`. `reopenLastClosed`'s `.project` case is untouched.

```swift
    /// Rebuilds one recorded tab, un-collapses its project and selects it. The body ⌘⇧T's
    /// `.session` case and the phone's `reopenClosedSession` both run, so the two surfaces
    /// cannot disagree about what a reopen does.
    ///
    /// Appends to `deferredCodexResumes` rather than settling anything itself: a caller
    /// reopening a whole project has several of these to collect before it starts one task.
    private func reopenSession(
        _ closed: ClosedSessionHistory.ClosedSession,
        directoryExists: (String) -> Bool,
        deferredCodexResumes: inout [UUID]
    ) {
        if reinsertClosed(closed, directoryExists: directoryExists) {
            deferredCodexResumes.append(closed.session.id)
        }
        // Matching `addSession` rather than `insertSession`: a tab reopened into a collapsed
        // project would otherwise come back invisible, since `SidebarRow.rows` renders only
        // the header for a collapsed repo. The `.project` case deliberately does not do this —
        // a project that was collapsed when it was closed is restored collapsed, because that
        // is the state being undone.
        let url = URL(fileURLWithPath: closed.projectPath, isDirectory: true)
        if let target = indexOfRepo(for: url), repos[target].isCollapsed {
            repos[target].isCollapsed = false
            emit(.projectCollapsed(id: repos[target].id, isCollapsed: false))
        }
        selectedSessionID = closed.session.id
    }

    /// Persist, then start any codex tab whose resume text still has to be settled.
    ///
    /// Reuses `restore`'s task handle rather than adding a second one: the two never run
    /// concurrently in production — `restore` happens once at launch, before any tab can be
    /// closed — and sharing it keeps one place to await a settling codex tab.
    private func settleReopen(_ deferredCodexResumes: [UUID]) {
        persist()
        if !deferredCodexResumes.isEmpty {
            codexRestoreTask = Task { [weak self] in
                await self?.resumeRestoredCodex(deferredCodexResumes)
            }
        }
    }

    /// The top-level closed tabs, most recent first — what `FleetService` projects onto the
    /// wire for the phone's Recently Closed section.
    var recentlyClosedSessions: [ClosedSessionHistory.ClosedSession] {
        closedSessions.sessionEntries
    }

    /// Reopen one recorded tab by id, rather than whatever is on top of the stack.
    ///
    /// The phone's counterpart to ⌘⇧T. A no-op when the id is not in the history — ⌘⇧T got
    /// there first, or it aged past `depth`. Deliberately silent: the tab is in the fleet list
    /// either way, so there is nothing to tell the phone that it cannot already see.
    func reopenClosedSession(
        id: UUID,
        directoryExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) {
        guard let closed = closedSessions.takeSession(id: id) else { return }
        var deferredCodexResumes: [UUID] = []
        reopenSession(closed, directoryExists: directoryExists,
                      deferredCodexResumes: &deferredCodexResumes)
        settleReopen(deferredCodexResumes)
    }
```

Then in `reopenLastClosed`, the `.session` case becomes:

```swift
        case .session(let closed):
            reopenSession(closed, directoryExists: directoryExists,
                          deferredCodexResumes: &deferredCodexResumes)
```

and the tail of `reopenLastClosed` (the `persist()` call and the `codexRestoreTask` block)
becomes `settleReopen(deferredCodexResumes)`.

- [ ] **Step 4: Run the whole macOS suite**

Run: `scripts/test-unit.sh`
Expected: PASS. The whole suite, not just the new file — `reopenLastClosed` was refactored and
`CloseSelectedSessionTests` and `CodexRuntimeAttachmentTests` both exercise it.

- [ ] **Step 5: Commit**

```bash
git add Sources/FlightDeck/SessionStore.swift Tests/FlightDeckTests/ReopenClosedSessionTests.swift
git commit -m "feat: reopen a recorded tab by id, sharing the body with cmd-shift-T"
```

---

### Task 3: The wire vocabulary

**Files:**
- Create: `Sources/FleetKit/ClosedSessions.swift`
- Modify: `Sources/FleetKit/TimelineFrames.swift` (`FleetRequest`), `Sources/FleetKit/Frames.swift`
  (`FleetCommand`, `ServerFrame`)
- Test: `Tests/FlightDeckTests/FleetFrameCodingTests.swift`,
  `Tests/FlightDeckTests/TimelineFrameCodingTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `WireClosedSession(id:title:agent:projectPath:)`;
  `FleetRequest.recentlyClosed`; `ServerFrame.recentlyClosed(cid: Int, [WireClosedSession])`;
  `FleetCommand.reopenClosed(session: UUID)`.

- [ ] **Step 1: Write the failing tests**

In `Tests/FlightDeckTests/TimelineFrameCodingTests.swift`:

```swift
    func testTheRecentlyClosedRequestRoundTrips() throws {
        let frame = ClientFrame.req(cid: 9, .recentlyClosed)
        let data = try JSONEncoder().encode(frame)
        XCTAssertEqual(try JSONDecoder().decode(ClientFrame.self, from: data), frame)
        // The op reads as one line in a packet dump, flattened beside the cid.
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(json["op"] as? String, "session.recentlyClosed")
    }
```

In `Tests/FlightDeckTests/FleetFrameCodingTests.swift`:

```swift
    func testTheRecentlyClosedReplyRoundTripsAndCarriesNoSeq() throws {
        let frame = ServerFrame.recentlyClosed(cid: 4, [
            WireClosedSession(id: UUID(), title: "fix the pager",
                              agent: "claude", projectPath: "/w/a")
        ])
        let data = try JSONEncoder().encode(frame)
        XCTAssertEqual(try JSONDecoder().decode(ServerFrame.self, from: data), frame)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertNil(json["seq"], "a reopen list is not fleet state and must not move the resume point")
    }

    func testTheReopenCommandRoundTrips() throws {
        let frame = ClientFrame.cmd(cid: 7, .reopenClosed(session: UUID()))
        let data = try JSONEncoder().encode(frame)
        XCTAssertEqual(try JSONDecoder().decode(ClientFrame.self, from: data), frame)
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `scripts/test-unit.sh -only-testing:FlightDeckTests/FleetFrameCodingTests -only-testing:FlightDeckTests/TimelineFrameCodingTests`
Expected: FAIL — `type 'FleetRequest' has no member 'recentlyClosed'`.

- [ ] **Step 3: Add the type**

Create `Sources/FleetKit/ClosedSessions.swift`:

```swift
import Foundation

/// One reopenable tab, as the Mac describes it for the phone's Recently Closed section.
///
/// **Identity and label, and nothing that derives a path.** `FleetSnapshot`'s doc comment gives
/// the rule this follows: `pinnedConversationID`, `transcriptDirectory` and
/// `transcriptPath` exist to resolve files on the Mac, and shipping them would put the Mac's
/// filesystem layout on a phone's disk for no rendering benefit. The Mac keeps the whole
/// recorded `Session` and looks it up again by `id` when a reopen comes back.
///
/// `projectPath` is already public — `WireProject.path` carries it today — and is here so the
/// phone can bucket one global list into per-project menus without a second request per
/// project.
public struct WireClosedSession: Codable, Equatable, Sendable, Identifiable {
    /// The tab's id, which is what `FleetCommand.reopenClosed` names. Never the conversation
    /// id, for `WireSession.id`'s reason.
    public let id: UUID
    public let title: String
    /// `AgentID.rawValue`, carried as a plain `String` for `WireSession.agent`'s reason: a
    /// client-side enum would throw on an agent added after the client shipped.
    public let agent: String
    /// The sidebar project this tab was filed under, matched against `WireProject.path`.
    public let projectPath: String

    public init(id: UUID, title: String, agent: String, projectPath: String) {
        self.id = id
        self.title = title
        self.agent = agent
        self.projectPath = projectPath
    }
}
```

- [ ] **Step 4: Add the request case**

In `Sources/FleetKit/TimelineFrames.swift`, add to `FleetRequest` beside `newSessionOptions`:

```swift
    /// Every reopenable tab the Mac is holding, across all projects.
    ///
    /// **A request rather than snapshot state**, for the reason `newSessionOptions` records and
    /// a sharper one: the history is not rebuildable from fleet events. `sessionRemoved` carries
    /// an id and nothing else — no project path, no index, no pinned conversation — so a
    /// `FleetReplicator` replay could not reconstruct it and its drift assertion would fail.
    ///
    /// **Global rather than per-project, unlike `newSessionOptions`.** That one is per-project
    /// because each project resolves genuinely different rows out of preferences; here there is
    /// one stack on the Mac and bucketing it by `projectPath` on the phone is a filter, not a
    /// second implementation. It is also one frame per refresh instead of N, which matters
    /// because the phone refreshes this on every fleet event.
    case recentlyClosed
```

Add `case recentlyClosed = "session.recentlyClosed"` to its private `Op` enum, then the encode
arm (`try c.encode(Op.recentlyClosed, forKey: .op)`, no other keys) and the decode arm
(`case .recentlyClosed: self = .recentlyClosed`) — both modelled on `.macEndpoints`, which is
the other argument-free request.

- [ ] **Step 5: Add the reply frame**

In `Sources/FleetKit/Frames.swift`, add to `ServerFrame`:

```swift
    /// The reply to `FleetRequest.recentlyClosed`. Unsequenced for the same reason `page` and
    /// `newSessionOptions` are: a reopen list is not fleet state, and giving it a `seq` would
    /// move the resume point a client hands back on its next `hello`.
    case recentlyClosed(cid: Int, [WireClosedSession])
```

Add `closed` to `ServerFrame.CodingKeys` and to its private `Tag` enum — **undotted**, per the
Global Constraints. Then the encode arm and the decode arm, both modelled on `.macEndpoints`
(the other frame whose payload is a bare array).

- [ ] **Step 6: Add the command**

In `Sources/FleetKit/Frames.swift`, add to `FleetCommand`:

```swift
    /// Reopen the closed tab `session`, exactly as ⌘⇧T aimed at that entry would.
    ///
    /// **Unreachable until `FleetRequest.recentlyClosed` has been answered, and that ordering
    /// is load-bearing.** `FleetCommand` throws on an unknown op and a `cmd` is NOT salvaged by
    /// `FleetSocketServer`'s `onUndecodable` — only a `req` is — so sending this to a Mac built
    /// before the feature would drop the connection. It is safe only because an old Mac refuses
    /// the request, which leaves the phone with no section and no row to tap.
    ///
    /// A no-op on the Mac when the entry has gone: ⌘⇧T consumed it, or it aged past
    /// `ClosedSessionHistory.depth`. Answered with `ack` either way — the tab is in the fleet
    /// list in both outcomes, so there is nothing a refusal would tell the phone.
    case reopenClosed(session: UUID)
```

Add `case reopenClosed = "session.reopen"` to `FleetCommand`'s private `Op`. Encode the id under
the existing `.id` coding key — that key already means "the session this command addresses" in
`markRead`, `closeSession` and `renameSession`, and a new key for the same meaning would be a
second spelling of one idea.

- [ ] **Step 7: Run the tests to verify they pass**

Run: `scripts/test-unit.sh -only-testing:FlightDeckTests/FleetFrameCodingTests -only-testing:FlightDeckTests/TimelineFrameCodingTests`
Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add Sources/FleetKit/ClosedSessions.swift Sources/FleetKit/Frames.swift Sources/FleetKit/TimelineFrames.swift Tests/FlightDeckTests/FleetFrameCodingTests.swift Tests/FlightDeckTests/TimelineFrameCodingTests.swift
git commit -m "feat: wire vocabulary for reopening a closed tab from a client"
```

---

### Task 4: `FleetConnector` correlates the answer

**Files:**
- Modify: `Sources/FleetKit/FleetConnector.swift`
- Test: `Tests/FlightDeckTests/FleetConnectorRequestTests.swift`

**Interfaces:**
- Consumes: `FleetRequest.recentlyClosed`, `ServerFrame.recentlyClosed`.
- Produces:
  `FleetConnector.requestRecentlyClosed(then: @escaping (Result<[WireClosedSession], FleetRequestError>) -> Void)`.

- [ ] **Step 1: Write the failing tests**

Read `Tests/FlightDeckTests/FleetConnectorRequestTests.swift` first and reuse its existing
harness for standing up a connector against a `FleetSocketServer`. Add, in that file's style:

```swift
    func testRecentlyClosedResolvesOnItsOwnCID() async throws { /* … mirror the newSessionOptions test in this file, with FleetRequest.recentlyClosed and a ServerFrame.recentlyClosed reply … */ }

    func testAnErrForARecentlyClosedRequestFailsThatCompletionOnce() async throws { /* … mirror the newSessionOptions err test: reply .err(cid:code: "unsupported"), assert one .failure(.server(code: "unsupported")) and no second call … */ }
```

Write both out in full against the harness that file already has — do not leave the comment
placeholders above in the committed test.

- [ ] **Step 2: Run to verify they fail**

Run: `scripts/test-unit.sh -only-testing:FlightDeckTests/FleetConnectorRequestTests`
Expected: FAIL — `value of type 'FleetConnector' has no member 'requestRecentlyClosed'`.

- [ ] **Step 3: Implement**

Add the pending table beside `pendingSession`:

```swift
    /// An eighth answer type, same reasoning as the seven above: one table per answer shape,
    /// all sharing the single `cid` space `FleetClient.send` mints from, so a number is filed
    /// in at most one and `apply` tries each in turn.
    private var pendingClosed: [Int: (Result<[WireClosedSession], FleetRequestError>) -> Void] = [:]
```

The request, modelled on `requestMacEndpoints` (the other argument-free one):

```swift
    /// Ask for every reopenable tab the Mac is holding. Same contract as `request(_:then:)` —
    /// exactly one answer, `.disconnected` synchronously when there is nothing to ask.
    public func requestRecentlyClosed(
        then completion: @escaping (Result<[WireClosedSession], FleetRequestError>) -> Void
    ) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let winner else { return completion(.failure(.disconnected)) }
        let cid = winner.send(FleetRequest.recentlyClosed)
        guard cid != 0 else { return completion(.failure(.disconnected)) }
        pendingClosed[cid] = completion
    }

    private func resolveClosed(
        _ cid: Int, with result: Result<[WireClosedSession], FleetRequestError>
    ) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let completion = pendingClosed.removeValue(forKey: cid) else { return }
        completion(result)
    }
```

The dispatch arm, beside `.macEndpoints`:

```swift
        case .recentlyClosed(let cid, let closed):
            // Unsequenced, exactly like `page` and `newSessionOptions` and for the same
            // reason — a reopen list is not fleet state and must not move the resume point.
            resolveClosed(cid, with: .success(closed))
            return
```

And in the `.err` arm, add before the trailing `resolve(cid:…)`, keeping the existing
commands-then-requests order:

```swift
            if pendingClosed[cid] != nil {
                resolveClosed(cid, with: .failure(.server(code: code)))
                return
            }
```

Add `pendingClosed` to whatever drains the other pending tables on disconnect — find it by
searching for `pendingSession.removeAll` (or the equivalent) and follow the same shape, so a
dropped connection fails this completion rather than leaking it.

- [ ] **Step 4: Run to verify they pass**

Run: `scripts/test-unit.sh -only-testing:FlightDeckTests/FleetConnectorRequestTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/FleetKit/FleetConnector.swift Tests/FlightDeckTests/FleetConnectorRequestTests.swift
git commit -m "feat: correlate the recently-closed answer on the connector"
```

---

### Task 5: The Mac answers and acts

**Files:**
- Create: `Sources/FlightDeck/Fleet/ClosedSessionProjection.swift`
- Create: `Tests/FlightDeckTests/ClosedSessionProjectionTests.swift`
- Modify: `Sources/FlightDeck/Fleet/FleetService.swift` (`onRequest` at ~339, `apply` at ~868)
- Test: `Tests/FlightDeckTests/FleetAccountEmissionTests.swift`

**Interfaces:**
- Consumes: `SessionStore.recentlyClosedSessions`, `SessionStore.reopenClosedSession(id:)`,
  `WireClosedSession`, `ServerFrame.recentlyClosed`, `FleetCommand.reopenClosed`.
- Produces: `ClosedSessionProjection.rows(for: [ClosedSessionHistory.ClosedSession]) -> [WireClosedSession]`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/FlightDeckTests/ClosedSessionProjectionTests.swift`:

```swift
// Tests/FlightDeckTests/ClosedSessionProjectionTests.swift
import FleetKit
import XCTest
@testable import FlightDeck

/// The reopen stack described for a phone. Pure, and separate from `FleetService`, so the
/// privacy property can be asserted without a socket — the same split
/// `NewSessionOptionsProjection` makes and for the same reason.
final class ClosedSessionProjectionTests: XCTestCase {
    private func closed(_ title: String, in project: String) -> ClosedSessionHistory.ClosedSession {
        ClosedSessionHistory.ClosedSession(
            session: Session(title: title, workingDirectory: project),
            projectPath: project, indexInProject: 0
        )
    }

    func testARowCarriesTheTabIDTitleAgentAndProjectPath() {
        let entry = closed("fix the pager", in: "/w/a")
        let rows = ClosedSessionProjection.rows(for: [entry])

        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].id, entry.session.id)
        XCTAssertEqual(rows[0].title, "fix the pager")
        XCTAssertEqual(rows[0].agent, entry.session.agent.rawValue)
        XCTAssertEqual(rows[0].projectPath, "/w/a")
    }

    /// Order is the stack's, not re-sorted here: `sessionEntries` already hands them over
    /// most-recent-first and the phone renders them in arrival order.
    func testOrderIsPreserved() {
        let rows = ClosedSessionProjection.rows(for: [
            closed("newest", in: "/w/a"), closed("older", in: "/w/b")
        ])
        XCTAssertEqual(rows.map(\.title), ["newest", "older"])
    }
}
```

In `Tests/FlightDeckTests/FleetAccountEmissionTests.swift`, extend the existing
"nothing that resolves to a home reaches the wire" assertion to cover an encoded
`ServerFrame.recentlyClosed` — read that file and follow whatever shape its current
assertion uses rather than inventing a parallel one.

- [ ] **Step 2: Run to verify they fail**

Run: `scripts/test-unit.sh -only-testing:FlightDeckTests/ClosedSessionProjectionTests`
Expected: FAIL — `cannot find 'ClosedSessionProjection' in scope`.

- [ ] **Step 3: Write the projection**

Create `Sources/FlightDeck/Fleet/ClosedSessionProjection.swift`:

```swift
import FleetKit
import Foundation

/// The reopen stack, described for a phone.
///
/// Pure, and separate from `FleetService`, so the privacy property can be tested without a
/// socket — the same split `NewSessionOptionsProjection` makes.
///
/// **Nothing that resolves to a path travels.** The recorded `Session` carries
/// `pinnedConversationID`, `transcriptDirectory` and `transcriptPath`; none of them are read
/// here. The Mac keeps the whole value and looks it up again by `id` when a reopen comes back,
/// which is what lets the wire row be four fields.
enum ClosedSessionProjection {
    /// In the order given — `ClosedSessionHistory.sessionEntries` is already most-recent-first
    /// and the phone renders arrival order.
    static func rows(for entries: [ClosedSessionHistory.ClosedSession]) -> [WireClosedSession] {
        entries.map { entry in
            WireClosedSession(
                id: entry.session.id,
                title: entry.session.title,
                agent: entry.session.agent.rawValue,
                projectPath: entry.projectPath
            )
        }
    }
}
```

- [ ] **Step 4: Wire it into `FleetService`**

In the `server.onRequest` switch, after the `.newSessionOptions` arm:

```swift
            case .recentlyClosed:
                // Answered synchronously, the same as `newSessionOptions` and `macEndpoints`:
                // the stack is in memory on this actor, so there is nothing to hop a `Task`
                // for and `reply` lands on `queue` as `onRequest` requires.
                //
                // Nothing here writes and nothing enters `FleetSnapshot` — the history is not
                // rebuildable from fleet events at all (`sessionRemoved` carries an id and
                // nothing else), which is the sharpest version of the shape
                // `FleetReplicator`'s drift assertion catches.
                //
                // An empty list is a real answer and is sent as one: it means nothing has been
                // closed this run. The phone renders no section, which is the same outcome as
                // never having asked — but this end has no reason to distinguish them.
                reply(.recentlyClosed(
                    cid: cid,
                    ClosedSessionProjection.rows(for: self.store.recentlyClosedSessions)
                ))
```

In `apply(_:from:cid:)`, after the `.closeSession` arm:

```swift
        case .reopenClosed(let session):
            // No `guard`, and deliberately no `err`. The entry may have gone since the phone
            // last asked — ⌘⇧T consumed it, or it aged past `ClosedSessionHistory.depth` — and
            // `reopenClosedSession` is a no-op on an id it does not hold. Both outcomes leave
            // the tab visible in the fleet list or genuinely gone, so a refusal would tell the
            // phone nothing it cannot already see. Compare `newSession`'s stale-`accountIndex`
            // fallback, which is refused for the opposite reason: there, a silent wrong account
            // is worse than an error.
            store.reopenClosedSession(id: session)
```

- [ ] **Step 5: Run the whole macOS suite**

Run: `scripts/test-unit.sh`
Expected: PASS. The whole suite — `FleetReplicator`'s drift assertion runs here and is the
check that nothing leaked into `FleetSnapshot`.

- [ ] **Step 6: Commit**

```bash
git add Sources/FlightDeck/Fleet/ClosedSessionProjection.swift Sources/FlightDeck/Fleet/FleetService.swift Tests/FlightDeckTests/ClosedSessionProjectionTests.swift Tests/FlightDeckTests/FleetAccountEmissionTests.swift
git commit -m "feat: answer the recently-closed request and act on a reopen"
```

---

### Task 6: The phone's section

**Files:**
- Modify: `Sources/FlightDeckMobile/FleetModel.swift` (state near `newSessionOptions` at ~282;
  `connect()`'s `onFleet` closure at ~457)
- Modify: `Sources/FlightDeckMobile/FleetListScreen.swift` (`newSessionMenu(for:)` at ~415)
- Test: `Tests/FlightDeckMobileTests/FleetModelTests.swift`,
  `Tests/FlightDeckMobileTests/FleetListScreenTests.swift`

**Interfaces:**
- Consumes: `FleetConnector.requestRecentlyClosed(then:)`, `FleetCommand.reopenClosed(session:)`,
  `WireClosedSession`.
- Produces: `FleetModel.recentlyClosed: [WireClosedSession]`, `FleetModel.refreshRecentlyClosed()`,
  `FleetModel.reopenClosed(_ id: UUID)`, and the pure
  `FleetListScreen.closedRows(in: [WireClosedSession], forProjectAt: String) -> [WireClosedSession]`.

- [ ] **Step 1: Write the failing tests**

In `Tests/FlightDeckMobileTests/FleetListScreenTests.swift`, add tests against the pure helper —
that is where this screen's decisions are assertable from a unit-test bundle:

```swift
    func testClosedRowsAreFilteredToTheProjectAndCappedAtFive() {
        let mine = (0..<7).map {
            WireClosedSession(id: UUID(), title: "mine \($0)", agent: "claude", projectPath: "/w/a")
        }
        let theirs = WireClosedSession(
            id: UUID(), title: "theirs", agent: "claude", projectPath: "/w/b"
        )

        let rows = FleetListScreen.closedRows(in: mine + [theirs], forProjectAt: "/w/a")

        XCTAssertEqual(rows.count, 5)
        XCTAssertEqual(rows.map(\.title), ["mine 0", "mine 1", "mine 2", "mine 3", "mine 4"],
                       "arrival order is most-recent-first and is preserved")
        XCTAssertFalse(rows.contains(theirs))
    }

    func testAProjectWithNoClosedSessionsGetsNoRows() {
        let rows = FleetListScreen.closedRows(
            in: [WireClosedSession(id: UUID(), title: "theirs", agent: "claude",
                                   projectPath: "/w/b")],
            forProjectAt: "/w/a"
        )
        XCTAssertTrue(rows.isEmpty)
    }
```

In `Tests/FlightDeckMobileTests/FleetModelTests.swift`, add a test in that file's existing style
asserting that a snapshot delivered through the connector leaves `recentlyClosed` populated from
the Mac's answer. Read the file first and reuse its harness.

- [ ] **Step 2: Run to verify they fail**

Run: `scripts/test-ios.sh -only-testing:FlightDeckMobileTests/FleetListScreenTests`
Expected: FAIL — `type 'FleetListScreen' has no member 'closedRows'`.

- [ ] **Step 3: Add the model state and refresh**

In `Sources/FlightDeckMobile/FleetModel.swift`, beside `newSessionOptions`:

```swift
    /// Every reopenable tab the Mac is holding, across all projects, most recent first.
    ///
    /// One flat list rather than a per-project dictionary, because the Mac keeps one stack:
    /// `FleetListScreen.closedRows(in:forProjectAt:)` buckets it by `projectPath` at render
    /// time. Empty until the first answer, and empty is also what an older Mac leaves it —
    /// it refuses the request — so the section simply never renders there. Absent and empty
    /// do not need holding apart here, unlike `newSessionOptions`: both mean "no rows to show"
    /// and neither changes anything else on the screen.
    private(set) var recentlyClosed: [WireClosedSession] = []

    /// Ask for the whole reopen stack.
    ///
    /// Hung off `connect()`'s `onFleet`, which fires on snapshots **and on every folded
    /// event** — so a close at either end refreshes this without needing a hook of its own.
    /// That matters more here than for `refreshNewSessionOptions`, which shares the hook: a
    /// session the phone itself just closed has to appear in that project's `+` immediately,
    /// not after a background-and-return.
    func refreshRecentlyClosed() {
        guard let connector else { return }
        connector.requestRecentlyClosed { [weak self] result in
            guard let self else { return }
            // A failure leaves the last answer standing rather than blanking the section: an
            // older Mac refuses every time (`unsupported`), and a phone that cleared on each
            // refusal would be doing so on a fact that never changes.
            guard case .success(let closed) = result else { return }
            self.recentlyClosed = closed
        }
    }

    /// Reopen a closed tab on the Mac. Fire-and-forget, exactly like `newSession`: the tab
    /// arrives as a `sessionAdded` event and the list redraws itself.
    func reopenClosed(_ id: UUID) {
        connector?.send(.reopenClosed(session: id))
    }
```

In `connect()`'s `onFleet` closure, after the `refreshConversations()` call:

```swift
                // Same hook, and here the "every folded event" half is the point rather than a
                // side effect — see `refreshRecentlyClosed`.
                self?.refreshRecentlyClosed()
```

- [ ] **Step 4: Add the section**

In `Sources/FlightDeckMobile/FleetListScreen.swift`, add the pure helper beside `agentGroups`:

```swift
    /// This project's reopenable tabs, most recent first, capped for the menu.
    ///
    /// **The cap is applied here, not on the wire.** `ClosedSessionHistory.depth` is the Mac's
    /// own business and a second cap on the wire would be a number to keep in sync; this is a
    /// statement about how long a phone menu should be, which is only ever a phone question.
    ///
    /// Order is the Mac's and is never re-sorted, for `agentGroups`' reason: the stack decides
    /// recency and a phone that sorted its copy would disagree with ⌘⇧T about what is newest.
    static func closedRows(
        in closed: [WireClosedSession], forProjectAt path: String
    ) -> [WireClosedSession] {
        Array(closed.lazy.filter { $0.projectPath == path }.prefix(5))
    }
```

In `newSessionMenu(for:)`, after the existing `if let options … else if options == nil …` block
and still inside the `@ViewBuilder`:

```swift
        // Below the New rows, and only when there is something to offer: an empty section
        // would render its header over nothing. This is the phone's only undo for a close —
        // ⌘⇧T is a Mac chord and the swipe that closes a tab has no counterpart here.
        let closed = Self.closedRows(in: model.recentlyClosed, forProjectAt: project.path)
        if !closed.isEmpty {
            Section("Recently Closed") {
                ForEach(closed) { session in
                    Button {
                        model.reopenClosed(session.id)
                    } label: {
                        Label(session.title, systemImage: "arrow.uturn.backward")
                    }
                }
            }
        }
```

Leave the `+`'s `.disabled(model.newSessionOptions[project.id]?.isEmpty == true)` **exactly as
it is**. The `Menu` uses `primaryAction`, so enabling it for a project with no launchable agent
would make a plain tap fire `newSession` — a guaranteed refusal, which is what the disable
exists to prevent — and such a project's closed tabs are ones `resumeExisting` would mark
orphaned and never launch anyway.

- [ ] **Step 5: Run both suites**

Run: `scripts/test-ios.sh`
Then: `scripts/test-unit.sh`
Expected: PASS on both. Both are required — the macOS run does not cover
`Sources/FlightDeckMobile`, and this task is the first to touch FleetKit from the iOS side.

- [ ] **Step 6: Commit**

```bash
git add Sources/FlightDeckMobile/FleetModel.swift Sources/FlightDeckMobile/FleetListScreen.swift Tests/FlightDeckMobileTests/FleetModelTests.swift Tests/FlightDeckMobileTests/FleetListScreenTests.swift
git commit -m "feat: a Recently Closed section in the phone's + menu"
```

---

## End-to-end verification

Not a substitute for the suites above — this is the part no unit test in either target reaches.

1. Build and launch the Mac app **in place** (never swap `/Applications`; that kills every
   other session on this machine).
2. On the phone, close a tab with a full swipe.
3. Long-press that project's `+` **without backgrounding the app**. The tab must be under
   Recently Closed already — that is the `onFleet`-fires-on-every-event path working.
4. Tap it. Confirm on the Mac that it comes back at its old sidebar position, selected, and
   resuming its real conversation rather than starting a fresh one.
5. Long-press `+` again: the row must be gone.
6. Close two more tabs on the Mac, reopen the *older* one from the phone, then press ⌘⇧T on the
   Mac. It must reopen the newer one — not the one already back — and the sidebar must hold no
   duplicate tab ids.
7. Check a codex tab specifically: reopening one goes through `resumeRestoredCodex`, which is
   the async path `settleReopen` starts and the only one a synchronous test cannot observe.
