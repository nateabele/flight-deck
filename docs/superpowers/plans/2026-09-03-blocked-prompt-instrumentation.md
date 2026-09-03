# Blocked-prompt Instrumentation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make an unnameable blocked dialog diagnosable from both machines, self-heal the one cause that is ours, and give a phone a way out of one.

**Architecture:** Three independent additions. A per-tick assertion in `SessionStore.applyRegistry` that compares the transcript the Mac is reading against the one the registry says `claude` is writing, logging the difference and repairing it. One `PhoneLog` line where the phone's existing retry schedule gives up. One new wire command carrying no call id, whose handler reuses the existing Escape path.

**Tech Stack:** Swift 6, SwiftUI, XCTest. FleetKit (shared), FlightDeck (macOS), FlightDeckMobile (iOS).

**Spec:** `docs/superpowers/specs/2026-09-03-blocked-prompt-instrumentation-design.md` (commit `a2f1616`)

## Global Constraints

- **A new `FleetCommand` case and its handler arms land in ONE commit.** Every switch over it is exhaustive; splitting them does not compile.
- **`PromptLifecycleLog` is observability only.** Nothing reads a record back; no branch is taken on one. The self-heal in Task 2 branches on the *registry*, never on a log record.
- **Path comparisons for `pathMatches` are raw string equality.** Never `SessionStore.comparablePath`. `ClaudeSession.encodedProjectDirName` maps every non-alphanumeric byte to `-`, so a symlink and its target encode to different project dirs; normalising would call a genuine mismatch a match.
- **Both suites must pass:** `scripts/test-unit.sh` (macOS; ignores `-only-testing:` and runs the full suite, ~8 min — budget for it, do not investigate) and `scripts/test-ios.sh` (required for any change under `Sources/FlightDeckMobile`).
- **`PromptService.tailRecords` is `8`.** Reuse it; do not introduce a second tail size.
- Do not run `scripts/smoke.sh` — it steals focus for ~40s and its failures will be spurious.

---

### Task 1: The `stuck` record

**Files:**
- Modify: `Sources/FlightDeck/Fleet/PromptLifecycleLog.swift`
- Test: `Tests/FlightDeckTests/PromptLifecycleLogTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `PromptLifecycleRecord.Event.stuck(code:watched:registryCWD:pathMatches:fileAgeMS:lastRecordAgeMS:tailRecords:)` and `.aborted(code:)`, both rendered by the existing `summary`.

- [ ] **Step 1: Write the failing test**

```swift
func testStuckRecordNamesBothPathsAndTheVerdict() {
    let record = PromptLifecycleRecord(
        session: UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!,
        event: .stuck(
            code: "prompt_changed",
            watched: "/p/-a-b/x.jsonl", registryCWD: "/a/b/.claude/worktrees/w",
            pathMatches: false, fileAgeMS: 61_000, lastRecordAgeMS: 61_000, tailRecords: 8
        )
    )
    XCTAssertTrue(record.summary.contains("stuck code=prompt_changed"))
    XCTAssertTrue(record.summary.contains("pathMatches=false"))
    XCTAssertTrue(record.summary.contains("watched=/p/-a-b/x.jsonl"))
    XCTAssertTrue(record.summary.contains("registryCwd=/a/b/.claude/worktrees/w"))
    XCTAssertTrue(record.summary.contains("fileAgeMs=61000"))
    XCTAssertTrue(record.summary.contains("lastRecordAgeMs=61000"))
}

func testAbortedRecordDistinguishesDispatchFromRefusal() {
    let ok = PromptLifecycleRecord(session: UUID(), event: .aborted(code: nil))
    XCTAssertTrue(ok.summary.contains("abort code=ok"))
    let no = PromptLifecycleRecord(session: UUID(), event: .aborted(code: "not_waiting"))
    XCTAssertTrue(no.summary.contains("abort code=not_waiting"))
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `scripts/test-unit.sh`
Expected: compile failure — `.stuck` and `.aborted` are not members of `Event`.

- [ ] **Step 3: Add the cases and their rendering**

In `PromptLifecycleRecord.Event`, after `case answer(...)`:

```swift
    /// A dialog this Mac still cannot name a second tick after it first could not.
    ///
    /// **One tick of `unnamed` is ordinary** — claude writes its status file and its
    /// transcript by independent paths, so `waiting` routinely arrives first and the very
    /// next poll names the call (16:37:57 `unnamed` → 16:37:58 `opened`). This case is the
    /// state that is NOT that: still blocked, still unnameable, and now worth a person's
    /// attention. It carries the two paths side by side because which of them is wrong is
    /// the whole question — `pathMatches == false` is this Mac reading a file `claude`
    /// left, and `pathMatches == true` with a stale `lastRecordAgeMs` is a record that was
    /// never written, which is upstream and not ours.
    case stuck(
        code: String, watched: String?, registryCWD: String?, pathMatches: Bool,
        fileAgeMS: Int?, lastRecordAgeMS: Int?, tailRecords: Int
    )
    /// An Escape sent at a dialog nothing could name. A sibling of `answer`, not a reuse of
    /// it: `answer` carries `sent` and `open` so a reader can see which machine was wrong
    /// about *which call*, and an abort names no call on either side. Forcing a sentinel
    /// through those fields would make "no call id by construction" read as a truncated line.
    case aborted(code: String?)
```

In `private var body`, before the closing brace:

```swift
        case .stuck(let code, let watched, let registryCWD, let matches,
                    let fileAge, let recordAge, let tail):
            return "stuck code=\(code) pathMatches=\(matches)"
                + " watched=\(watched ?? "-") registryCwd=\(registryCWD ?? "-")"
                + " fileAgeMs=\(fileAge.map(String.init) ?? "-")"
                + " lastRecordAgeMs=\(recordAge.map(String.init) ?? "-")"
                + " tailRecords=\(tail)"
        case .aborted(let code):
            return "abort code=\(code ?? "ok")"
```

- [ ] **Step 4: Run to verify it passes**

Run: `scripts/test-unit.sh`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/FlightDeck/Fleet/PromptLifecycleLog.swift Tests/FlightDeckTests/PromptLifecycleLogTests.swift
git commit -m "feat: record a dialog this Mac still cannot name"
```

---

### Task 2: Detect stuck on the registry tick, and self-heal a wrong path

**Files:**
- Modify: `Sources/FlightDeck/SessionStore.swift` (`applyRegistry(_:from:)`, ~4486; `retarget(_:to:)`, ~4986)
- Test: `Tests/FlightDeckTests/SessionStoreStuckPromptTests.swift` (create)

**Interfaces:**
- Consumes: `PromptLifecycleRecord.Event.stuck` (Task 1); `PromptService.openPrompt(inSession:)`; `ClaudeSession.transcriptURL(sessionID:workingDirectory:projectsRoot:)`; `SessionStore.retarget(_:to:)`; `ClaudeStatusFile.Entry.cwd`.
- Produces: `SessionStore.stuckPromptTicks: [UUID: Int]` (private) and the test seam `func stuckCheckForTesting(rows:)`.

**Why here and not in `PromptLifecycleObserver`:** that observer is event-driven — `note(_:activity:clients:)` runs off `activityChanged`, and a session that stays `waiting` emits no further activity event. That is exactly why `unnamed` was logged once at 16:43:28 and never again. `applyRegistry` is the periodic tick and already holds `rows`, so `registryCWD` needs no new lookup.

- [ ] **Step 1: Write the failing test**

```swift
@MainActor
func testSecondConsecutiveUnnameableTickRetargetsAMismatchedPath() throws {
    let store = SessionStore.fixture()
    let tab = store.openFixtureSession(waitingWithNoOpenCall: true)
    let worktree = "/Users/x/proj/.claude/worktrees/w"
    let rows = [pid_t(4242): ClaudeStatusFile.Entry.fixture(
        pid: 4242, sessionID: store.pinnedConversationID(of: tab)!, cwd: worktree
    )]

    store.stuckCheckForTesting(rows: rows)          // tick 1: ordinary race, silent
    XCTAssertEqual(store.transcriptDirectory(of: tab), "/Users/x/proj")

    store.stuckCheckForTesting(rows: rows)          // tick 2: stuck, and mismatched
    XCTAssertEqual(store.transcriptDirectory(of: tab), worktree,
                   "a mismatched path must be repaired on the spot, not left for a later tick")
}

@MainActor
func testOneTickOfUnnameableEmitsNothingAndChangesNothing() throws {
    let store = SessionStore.fixture()
    let tab = store.openFixtureSession(waitingWithNoOpenCall: true)
    let rows = [pid_t(4242): ClaudeStatusFile.Entry.fixture(
        pid: 4242, sessionID: store.pinnedConversationID(of: tab)!, cwd: "/Users/x/proj"
    )]
    store.stuckCheckForTesting(rows: rows)
    XCTAssertEqual(store.transcriptDirectory(of: tab), "/Users/x/proj")
}

@MainActor
func testAMatchingPathIsNeverRetargeted() throws {
    let store = SessionStore.fixture()
    let tab = store.openFixtureSession(waitingWithNoOpenCall: true)
    let rows = [pid_t(4242): ClaudeStatusFile.Entry.fixture(
        pid: 4242, sessionID: store.pinnedConversationID(of: tab)!, cwd: "/Users/x/proj"
    )]
    store.stuckCheckForTesting(rows: rows)
    store.stuckCheckForTesting(rows: rows)
    XCTAssertEqual(store.transcriptDirectory(of: tab), "/Users/x/proj",
                   "a path that already agrees must not be churned")
}

@MainActor
func testTheCounterResetsOnceTheDialogIsNameable() throws {
    let store = SessionStore.fixture()
    let tab = store.openFixtureSession(waitingWithNoOpenCall: true)
    let rows = [pid_t(4242): ClaudeStatusFile.Entry.fixture(
        pid: 4242, sessionID: store.pinnedConversationID(of: tab)!, cwd: "/Users/x/proj"
    )]
    store.stuckCheckForTesting(rows: rows)
    store.makeFixtureCallNameable(tab)
    store.stuckCheckForTesting(rows: rows)
    XCTAssertEqual(store.stuckTicksForTesting(tab), 0)
}
```

Follow the fixture helpers already used by the neighbouring store tests; add
`openFixtureSession(waitingWithNoOpenCall:)`, `makeFixtureCallNameable(_:)` and
`ClaudeStatusFile.Entry.fixture(pid:sessionID:cwd:)` to the existing fixture file
rather than a new one if they are not already there.

- [ ] **Step 2: Run to verify it fails**

Run: `scripts/test-unit.sh`
Expected: compile failure — `stuckCheckForTesting` does not exist.

- [ ] **Step 3: Implement the check**

Add to `SessionStore`:

```swift
    /// Consecutive registry ticks on which a `waiting` tab's dialog could not be named.
    /// Reset the moment it can be, so an ordinary race never reaches the threshold.
    private var stuckPromptTicks: [UUID: Int] = [:]

    /// The threshold, and why it is 2. One tick of `unnamed` is the ordinary race between
    /// claude's status file and its transcript; two means the record is not coming.
    private static let stuckPromptTickThreshold = 2

    func stuckCheckForTesting(rows: [pid_t: ClaudeStatusFile.Entry]) { checkStuckPrompts(rows) }
    func stuckTicksForTesting(_ id: UUID) -> Int { stuckPromptTicks[id] ?? 0 }

    /// Assert, once per tick, that a blocked tab this Mac cannot read is at least being read
    /// from the right file — and repair it when it is not.
    private func checkStuckPrompts(_ rows: [pid_t: ClaudeStatusFile.Entry]) {
        for session in repos.flatMap(\.sessions) {
            let id = session.id
            guard statuses[id]?.activity == .waiting else { stuckPromptTicks[id] = 0; continue }
            guard case .failure(let code) = promptService.openPrompt(inSession: id) else {
                stuckPromptTicks[id] = 0
                continue
            }
            let ticks = (stuckPromptTicks[id] ?? 0) + 1
            stuckPromptTicks[id] = ticks
            guard ticks == Self.stuckPromptTickThreshold else { continue }

            let watched = watchedTranscriptURL(of: id)
            let registryCWD = rows.values
                .first { $0.sessionID == session.pinnedConversationID }?.cwd
            // Raw equality, never `comparablePath` — see this plan's Global Constraints.
            let expected = registryCWD.map {
                ClaudeSession.transcriptURL(
                    sessionID: session.pinnedConversationID, workingDirectory: $0
                )
            }
            let matches = watched != nil && expected != nil && watched!.path == expected!.path

            PromptLifecycleLog.record(PromptLifecycleRecord(
                session: id,
                event: .stuck(
                    code: String(describing: code),
                    watched: watched?.path, registryCWD: registryCWD, pathMatches: matches,
                    fileAgeMS: watched.flatMap(Self.fileAgeMS(of:)),
                    lastRecordAgeMS: watched.flatMap(Self.lastRecordAgeMS(of:)),
                    tailRecords: PromptService.tailRecords
                )
            ))

            // The repair, and the only branch here that is not observation. It reads the
            // registry, never the record just written.
            if !matches, let cwd = registryCWD, !cwd.isEmpty, cwd != session.transcriptDirectory {
                retarget(id, to: cwd)
            }
        }
    }
```

Add the two small helpers beside it — `fileAgeMS(of:)` from the URL's
`contentModificationDate`, and `lastRecordAgeMS(of:)` from the newest `timestamp`
in `TranscriptPager.page(url:anchor:.latest, limit: PromptService.tailRecords)`.
Both return `nil` rather than throwing; this runs inside a tick.

Call it at the end of `applyRegistry(_:from:)`, after the existing resolution loop
so a retarget applied there is already visible:

```swift
        checkStuckPrompts(rows)
```

- [ ] **Step 4: Run to verify it passes**

Run: `scripts/test-unit.sh`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/FlightDeck/SessionStore.swift Tests/FlightDeckTests/
git commit -m "feat: assert a blocked tab's transcript path, and repair a stale one"
```

---

### Task 3: The gating preference and its snapshot field

**Files:**
- Modify: `Sources/FlightDeck/Preferences/PreferencesStore.swift`
- Modify: `Sources/FleetKit/Wire.swift` (`WireSession`)
- Modify: `Sources/FlightDeck/Fleet/FleetProjection.swift`
- Modify: `Sources/FlightDeck/Preferences/UI/DevicesSettingsTab.swift`
- Test: `Tests/FleetKitTests/WireCompatibilityTests.swift`, `Tests/FlightDeckTests/FleetProjectionTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `PreferencesStore.allowsBlockedPromptAbort: Bool` (default `false`) and `WireSession.allowsBlockedAbort: Bool` (default `false`).

- [ ] **Step 1: Write the failing test**

```swift
func testAnOlderPhoneDecodesASnapshotWithoutTheFlagAsOff() throws {
    let json = #"{"id":"00000000-0000-0000-0000-0000000000AA","title":"t","agent":"claude","subagentCount":0,"isUnread":false,"hasBackgroundWork":false}"#
    let session = try JSONDecoder().decode(WireSession.self, from: Data(json.utf8))
    XCTAssertFalse(session.allowsBlockedAbort,
                   "the field is additive; its absence must mean off, never a decode failure")
}

@MainActor
func testTheProjectionCarriesThePreference() {
    let prefs = PreferencesStore.fixture()
    prefs.allowsBlockedPromptAbort = true
    let snapshot = FleetProjection.snapshot(of: .fixture(preferences: prefs))
    XCTAssertTrue(snapshot.sessions.allSatisfy(\.allowsBlockedAbort))
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `scripts/test-unit.sh`
Expected: compile failure — `allowsBlockedAbort` / `allowsBlockedPromptAbort` do not exist.

- [ ] **Step 3: Implement**

`WireSession`, beside `openPromptCall`:

```swift
    /// Whether this Mac will honour `prompt.abort` for this tab.
    ///
    /// Carried rather than derived because it is a fact about the *Mac's* preferences, which
    /// the phone has no other way to see. Defaulted so a snapshot written by an older Mac
    /// decodes as off — the safe direction for a control that drives a terminal.
    public var allowsBlockedAbort: Bool = false
```

`PreferencesStore`, following `autoResumesRunningSessions` exactly:

```swift
    /// Whether a paired phone may send Escape at a dialog this Mac cannot name.
    ///
    /// Default off. The action itself is the same Escape the Deny button already sends, but
    /// it is sent *blind* — with no call id, because there is none — so it is opt-in until
    /// the deferred-flush case it exists for is understood.
    var allowsBlockedPromptAbort: Bool {
        get { preferences.claude?.allowsBlockedPromptAbort ?? false }
        set {
            var claude = preferences.claude ?? ClaudePreferences()
            claude.allowsBlockedPromptAbort = newValue
            preferences.claude = claude
        }
    }
```

Add the stored `allowsBlockedPromptAbort: Bool?` to `ClaudePreferences`, populate
`WireSession.allowsBlockedAbort` in `FleetProjection`, and add a checkbox to
`DevicesSettingsTab` labelled **"Allow phones to dismiss unreadable dialogs"**.

- [ ] **Step 4: Run to verify it passes**

Run: `scripts/test-unit.sh`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/FlightDeck Sources/FleetKit Tests/
git commit -m "feat: a preference for dismissing an unreadable dialog from a phone"
```

---

### Task 4: `prompt.abort` — wire case and handler, in one commit

**Files:**
- Modify: `Sources/FleetKit/Frames.swift` (`FleetCommand`, `CodingKeys`, `Op`)
- Modify: `Sources/FlightDeck/Fleet/FleetService.swift` (dispatch, ~1036)
- Modify: `Sources/FlightDeck/SessionStore.swift` (new `abortPrompt`)
- Test: `Tests/FleetKitTests/FleetCommandTests.swift`, `Tests/FlightDeckTests/SessionStoreAbortTests.swift`

**Interfaces:**
- Consumes: `PromptLifecycleRecord.Event.aborted` (Task 1); `PreferencesStore.allowsBlockedPromptAbort` (Task 3); the existing `AgentDialogDriver.deny(_:)`, `injector(for:)`, `injecting`, `remember(answered:for:)`.
- Produces: `FleetCommand.abortPrompt(id:token:)` (op `"prompt.abort"`) and `SessionStore.abortPrompt(in:token:) -> AnswerDispatch`.

**Both halves land together** — every switch over `FleetCommand` is exhaustive.

- [ ] **Step 1: Write the failing test**

```swift
func testAbortPromptRoundTripsAsPromptAbort() throws {
    let id = UUID(), token = UUID()
    let encoded = try JSONEncoder().encode(FleetCommand.abortPrompt(id: id, token: token))
    let object = try XCTUnwrap(
        JSONSerialization.jsonObject(with: encoded) as? [String: Any]
    )
    XCTAssertEqual(object["op"] as? String, "prompt.abort")
    XCTAssertEqual(try JSONDecoder().decode(FleetCommand.self, from: encoded),
                   .abortPrompt(id: id, token: token))
}

@MainActor
func testAbortRefusesInTheSameOrderAnAnswerDoes() {
    let store = SessionStore.fixture()
    XCTAssertEqual(store.abortPrompt(in: UUID(), token: UUID()), .unknownSession)

    let idle = store.openFixtureSession(waitingWithNoOpenCall: false)
    XCTAssertEqual(store.abortPrompt(in: idle, token: UUID()), .notWaiting,
                   "a stray Escape into a live TUI is not free")

    let blocked = store.openFixtureSession(waitingWithNoOpenCall: true)
    let token = UUID()
    XCTAssertEqual(store.abortPrompt(in: blocked, token: token), .dispatched)
    XCTAssertEqual(store.abortPrompt(in: blocked, token: token), .duplicate)
    XCTAssertEqual(store.fixtureInjector(blocked).sentKeys, [.escape],
                   "abort sends one key and reads no viewport")
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `scripts/test-unit.sh`
Expected: compile failure — no `abortPrompt`.

- [ ] **Step 3: Implement**

`FleetCommand`, after `answerPrompt`:

```swift
    /// Escape at a dialog this Mac cannot name.
    ///
    /// **It carries no call id, and that is the whole reason it exists.** `answerPrompt` is
    /// judged against the call the client had on screen; here there is none on either side —
    /// the record naming it never reached the transcript. So this is deliberately the one
    /// command that acts on a session rather than on a call, which is also why it is gated:
    /// see `WireSession.allowsBlockedAbort`.
    case abortPrompt(id: UUID, token: UUID)
```

Add `case abortPrompt = "prompt.abort"` to `Op` and encode/decode `id` and `token`
exactly as `answerPrompt` does, minus `call` and `answer`.

`SessionStore`, beside `answerPrompt`:

```swift
    /// Escape, sent blind. The guards are `answerPrompt`'s in the same order, minus the call
    /// comparison it has nothing to compare; the action is `driver.deny`, which is one key
    /// event with no viewport parse — the only thing that works on a screen this build
    /// cannot read, which is precisely the screen this is for.
    func abortPrompt(in id: UUID, token: UUID) -> AnswerDispatch {
        let outcome = dispatchAbort(in: id, token: token)
        PromptLifecycleLog.record(PromptLifecycleRecord(
            session: id,
            event: .aborted(code: outcome == .dispatched ? nil : String(describing: outcome))
        ))
        return outcome
    }

    private func dispatchAbort(in id: UUID, token: UUID) -> AnswerDispatch {
        guard let at = locate(id) else { return .unknownSession }
        guard let driver = repos[at.repo].sessions[at.session].agent.dialogDriver else {
            return .unsupportedAgent
        }
        if answeredPromptTokens[id, default: []].contains(token) { return .duplicate }
        guard statuses[id]?.activity == .waiting else { return .notWaiting }
        guard let injector = injector(for: id) else { return .unreadableScreen }
        guard !injecting.contains(id) else { return .unreadableScreen }
        remember(answered: token, for: id)
        driver.deny(injector)
        return .dispatched
    }
```

`FleetService`, beside the `.answerPrompt` arm at ~1036 — refuse when the
preference is off, before touching the store:

```swift
        case .abortPrompt(let id, let token):
            guard preferences.allowsBlockedPromptAbort else {
                return .failure(op: "prompt.abort", error: "unsupported_agent", detail: nil)
            }
            return result(of: store.abortPrompt(in: id, token: token), op: "prompt.abort")
```

Match the surrounding arms' exact result-construction helper rather than inventing
one; read the `.answerPrompt` arm directly above and mirror it.

- [ ] **Step 4: Run to verify it passes**

Run: `scripts/test-unit.sh`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/FleetKit/Frames.swift Sources/FlightDeck Tests/
git commit -m "feat: prompt.abort, an Escape for a dialog nothing can name"
```

---

### Task 5: Mobile — log where the chase gives up

**Files:**
- Modify: `Sources/FlightDeckMobile/SessionTimelineModel.swift` (`chaseBlockedPrompt`)
- Test: `Tests/FlightDeckMobileTests/SessionTimelineModelTests.swift`

**Interfaces:**
- Consumes: the existing `PhoneLog.prompt` logger (category `"prompt"`, already carried by `PhoneRequest`/`WirePhoneLogs`).
- Produces: `SessionTimelineModel.blockedChaseExhausted: Bool`, read by Task 6.

- [ ] **Step 1: Write the failing test**

```swift
@MainActor
func testExhaustingTheChaseMarksTheSessionBlocked() async {
    let model = SessionTimelineModel.fixture(activity: "waiting", withNoPromptRecord: true)
    model.promptRetries = [.milliseconds(1), .milliseconds(1)]
    await model.chaseBlockedPrompt(agent: "claude", activity: "waiting", call: .none)
    XCTAssertTrue(model.blockedChaseExhausted)
}

@MainActor
func testACardArrivingBeforeTheScheduleRunsOutLeavesItUnblocked() async {
    let model = SessionTimelineModel.fixture(activity: "waiting", withNoPromptRecord: false)
    await model.chaseBlockedPrompt(agent: "claude", activity: "waiting", call: .none)
    XCTAssertFalse(model.blockedChaseExhausted)
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `scripts/test-ios.sh`
Expected: FAIL — no `blockedChaseExhausted`.

- [ ] **Step 3: Implement**

Add `private(set) var blockedChaseExhausted = false`. Set it `false` on every entry
to `chaseBlockedPrompt` and whenever a card is obtained. Where the retry schedule
runs out with no card, set it `true` and log once:

```swift
        blockedChaseExhausted = true
        PhoneLog.prompt.notice("""
            blocked-chase-exhausted session=\(self.sessionID.uuidString, privacy: .public) \
            activity=\(activity ?? "-", privacy: .public) \
            retries=\(self.promptRetries.count, privacy: .public) \
            unansweredInFeed=\(self.hasUnansweredCallInFeed, privacy: .public)
            """)
```

`unansweredInFeed` is the fact that separates the two causes from the phone's side:
`false` means the record never reached this feed at all.

- [ ] **Step 4: Run to verify it passes**

Run: `scripts/test-ios.sh`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/FlightDeckMobile/SessionTimelineModel.swift Tests/FlightDeckMobileTests/
git commit -m "feat: record where the phone gives up chasing a blocked prompt"
```

---

### Task 6: Mobile — the Blocked state and its Abort button

**Files:**
- Modify: `Sources/FlightDeckMobile/PromptCard.swift`
- Modify: `Sources/FlightDeckMobile/FleetModel.swift` (send the command)
- Test: `Tests/FlightDeckMobileTests/PromptCardTests.swift`

**Interfaces:**
- Consumes: `blockedChaseExhausted` (Task 5); `WireSession.allowsBlockedAbort` (Task 3); `FleetCommand.abortPrompt` (Task 4).
- Produces: nothing downstream.

- [ ] **Step 1: Write the failing test**

```swift
@MainActor
func testBlockedAppearsOnlyAfterTheChaseGivesUpAndOnlyWhenAllowed() {
    XCTAssertFalse(PromptCard.showsBlocked(exhausted: false, allowsAbort: true, hasCard: false))
    XCTAssertFalse(PromptCard.showsBlocked(exhausted: true, allowsAbort: true, hasCard: true))
    XCTAssertFalse(PromptCard.showsBlocked(exhausted: true, allowsAbort: false, hasCard: false))
    XCTAssertTrue(PromptCard.showsBlocked(exhausted: true, allowsAbort: true, hasCard: false))
}

@MainActor
func testAbortSendsOneCommandPerToken() async {
    let model = FleetModel.fixture()
    let id = UUID()
    await model.abortBlockedPrompt(session: id)
    await model.abortBlockedPrompt(session: id)
    XCTAssertEqual(model.sentCommands.filter { $0.isAbort }.count, 1)
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `scripts/test-ios.sh`
Expected: FAIL — no `showsBlocked` / `abortBlockedPrompt`.

- [ ] **Step 3: Implement**

Add the pure predicate so the rule is testable without a view:

```swift
    /// Blocked replaces the bare "Waiting for you" only once the chase has actually given up
    /// (~18s), never on a single failed fetch — the ordinary race must keep looking like one.
    static func showsBlocked(exhausted: Bool, allowsAbort: Bool, hasCard: Bool) -> Bool {
        exhausted && allowsAbort && !hasCard
    }
```

Render, in the same visual idiom as the existing cards in this file: the label
**Blocked**, one line of body text — *"This Mac can't read the dialog on screen."* —
and one destructive-styled **Abort** button. `FleetModel.abortBlockedPrompt(session:)`
mints one token per blocked episode, caches it, and sends
`FleetCommand.abortPrompt(id:token:)`, so a double tap is the same token and the
Mac's `answeredPromptTokens` collapses it to `.duplicate`.

- [ ] **Step 4: Run to verify it passes**

Run: `scripts/test-ios.sh`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/FlightDeckMobile Tests/FlightDeckMobileTests/
git commit -m "feat: a Blocked state with an escape hatch"
```

---

### Task 7: Full-suite verification

- [ ] **Step 1:** Run `scripts/test-unit.sh` — full suite, ~8 min, `-only-testing:` is ignored.
- [ ] **Step 2:** Run `scripts/test-ios.sh`.
- [ ] **Step 3:** Fix any failure at its root cause; do not narrow a test to make it pass.
- [ ] **Step 4:** Commit any fixes.

Do not run `scripts/smoke.sh`, and do not swap `/Applications` to try the build —
a debug build launched in place is the only safe way to look at this by hand.

## Self-Review

**Spec coverage:** Part A → Tasks 1–2. Part B → Task 5. Part C → Task 6. Part D →
Tasks 3–4. Testing section → Tasks 1–7. Open decisions 1 (wording) is answered in
Task 6; decision 2 (Abort on a nameable dialog) is out of scope by the spec and no
task implements it.

**Placeholder scan:** every code step carries real code; the two places that defer
to surrounding style (the `FleetService` result helper in Task 4, the card idiom in
Task 6) name the exact file and neighbouring symbol to copy, rather than saying
"handle appropriately".

**Type consistency:** `blockedChaseExhausted` (Task 5 → 6), `allowsBlockedAbort`
(Task 3 → 6), `allowsBlockedPromptAbort` (Task 3 → 4), `.stuck` / `.aborted`
(Task 1 → 2, 4), `abortPrompt(in:token:)` vs `FleetCommand.abortPrompt(id:token:)`
— the store method and the wire case differ in label deliberately and are used
consistently.
