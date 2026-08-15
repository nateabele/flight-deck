# Auto-Resume & Persisted Unread — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Flight Deck remembers which sessions were working when it went away, offers an off-by-default preference to prompt them to continue on the next launch, and keeps unread marks across a relaunch.

**Architecture:** Each session's `SessionActivity` and unread flag are stamped into `sessions.json` whenever `statuses` genuinely changes, so an unclean exit is covered too. On restore, sessions recorded as `busy` or `shell` enter a pending-prompt map that is retried from the registry tick until the resumed `claude` is idle and its input box is readable — the same deferral machinery `flushPendingRename` already uses, extracted into one shared injector.

**Tech Stack:** Swift 5 language mode / Swift 6.3 compiler, SwiftUI, XCTest, xcodegen. macOS app, non-sandboxed.

**Spec:** `docs/superpowers/specs/2026-08-15-auto-resume-design.md` (Tasks 1–11. Task 12 is an
unrelated ⌘W fix folded in at the user's request and is specified inline in that task.)

## Global Constraints

- **Every new `Codable` field on a persisted type is `Optional`.** `UserDefaultsPreferencesPersistence.load()` and `FileSessionPersistence.load()` both decode with `try?`, and synthesized `Codable` throws on a missing key rather than using a property default. A non-optional field silently wipes the user's existing state on the first launch after the change. This is already documented on `Preferences.confirmations` and `SessionSnapshot.Entry.pinnedConversationID`.
- **Run tests with `./scripts/test-unit.sh`** from the repo root. It runs `xcodegen generate` itself, so new files need no `project.yml` change. It builds the whole app first — expect ~1–2 min on a warm DerivedData.
- **Do not run `./scripts/smoke.sh`.** It steals focus for ~40 s and this change is fully covered at the unit layer.
- **Do not `defaults delete dev.flightdeck.FlightDeck`.** Preferences live there.
- **This is a shared working copy.** Other sessions may have uncommitted files. `git add` only the exact paths each task names — never `git add -A` or `git commit -a`.
- **Injected text and Return are separate operations.** `sendText` is a *paste*, and Claude Code enables bracketed-paste mode, so a `\n` inside the payload is inserted as content and never submits. Return must go through `sendReturn()`. Never "simplify" this by putting a terminator in the text.
- The user-facing prompt string is exactly `Keep going`.
- The states that count as "was running" are exactly `.busy` and `.shell`. Not `.waiting`.

---

### Task 1: `ClaudePreferences` and the store accessor

**Files:**
- Modify: `Sources/FlightDeck/Preferences/Preferences.swift`
- Modify: `Sources/FlightDeck/Preferences/PreferencesStore.swift`
- Test: `Tests/FlightDeckTests/PreferencesStoreTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `struct ClaudePreferences: Codable, Equatable` with `var autoResumeRunningSessions: Bool`; `Preferences.claude: ClaudePreferences?`; `PreferencesStore.autoResumesRunningSessions: Bool` (get/set).

- [ ] **Step 1: Write the failing tests**

Append to `Tests/FlightDeckTests/PreferencesStoreTests.swift`, inside the existing class:

```swift
    // MARK: Auto-resume

    func testAutoResumeDefaultsOff() {
        let store = PreferencesStore(persistence: MemoryPersistence())
        XCTAssertFalse(store.autoResumesRunningSessions)
        XCTAssertNil(store.preferences.claude)
    }

    func testEnablingAutoResumePersists() {
        let persistence = MemoryPersistence()
        let store = PreferencesStore(persistence: persistence)
        store.autoResumesRunningSessions = true
        XCTAssertEqual(persistence.stored?.claude?.autoResumeRunningSessions, true)
        XCTAssertTrue(store.autoResumesRunningSessions)
    }

    func testDisablingAutoResumeRoundTrips() {
        let store = PreferencesStore(persistence: MemoryPersistence())
        store.autoResumesRunningSessions = true
        store.autoResumesRunningSessions = false
        XCTAssertFalse(store.autoResumesRunningSessions)
    }

    /// The load-bearing one. A `preferences.v1` blob written before this field existed must
    /// still decode — `load()` uses `try?`, so a throw here resets every flag, project
    /// override and shell setting the user has. Same trap as `Preferences.confirmations`.
    ///
    /// Built by encoding a real `Preferences` and deleting the key, rather than by hand, so
    /// the fixture cannot drift from whatever `FlagSet` actually encodes to.
    func testPreferencesWithoutTheClaudeKeyStillDecode() throws {
        let original = Preferences(
            globalFlags: FlagSet(values: ["--model": .value("opus")]),
            claude: ClaudePreferences(autoResumeRunningSessions: true)
        )
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try JSONEncoder().encode(original))
                as? [String: Any]
        )
        object.removeValue(forKey: "claude")
        let legacy = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(Preferences.self, from: legacy)

        XCTAssertNil(decoded.claude)
        XCTAssertEqual(decoded.globalFlags.values["--model"], .value("opus"))
        XCTAssertTrue(decoded.shell.clearChildSessionMarker)
    }

- [ ] **Step 2: Run tests to verify they fail**

Run: `./scripts/test-unit.sh 2>&1 | tail -40`
Expected: compile failure — `value of type 'PreferencesStore' has no member 'autoResumesRunningSessions'`.

- [ ] **Step 3: Add the model**

In `Sources/FlightDeck/Preferences/Preferences.swift`, add above `struct Preferences`:

```swift
/// Session-lifecycle behaviour, edited on the Claude tab.
struct ClaudePreferences: Codable, Equatable {
    /// Sessions that were mid-turn when Flight Deck last went away are prompted to continue
    /// once they have resumed and settled. Off by default: picking work back up unattended
    /// is a decision the user has to make deliberately, not one to inherit from an upgrade.
    var autoResumeRunningSessions: Bool

    init(autoResumeRunningSessions: Bool = false) {
        self.autoResumeRunningSessions = autoResumeRunningSessions
    }
}
```

Add the property to `Preferences`, after `confirmations`:

```swift
    /// Optional for exactly the reason `confirmations` is — see that property's comment.
    /// `nil` means "never configured", which reads as every field's default.
    var claude: ClaudePreferences?
```

and extend the initializer:

```swift
    init(
        globalFlags: FlagSet = FlagSet(),
        projectFlags: [String: FlagSet] = [:],
        shell: ShellPreferences = ShellPreferences(),
        confirmations: ConfirmationPreferences? = nil,
        claude: ClaudePreferences? = nil
    ) {
        self.globalFlags = globalFlags
        self.projectFlags = projectFlags
        self.shell = shell
        self.confirmations = confirmations
        self.claude = claude
    }
```

- [ ] **Step 4: Add the store accessor**

In `Sources/FlightDeck/Preferences/PreferencesStore.swift`, append a new section after the
`// MARK: Confirmations` block:

```swift
    // MARK: Claude

    /// Whether sessions recorded as working at shutdown are prompted to continue on the
    /// next launch. Reads through the optional so an unconfigured `Preferences` is off.
    var autoResumesRunningSessions: Bool {
        get { preferences.claude?.autoResumeRunningSessions ?? false }
        set {
            var claude = preferences.claude ?? ClaudePreferences()
            claude.autoResumeRunningSessions = newValue
            preferences.claude = claude
        }
    }
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `./scripts/test-unit.sh 2>&1 | tail -20`
Expected: `** TEST SUCCEEDED **` (or the equivalent `Executed N tests, with 0 failures`).

- [ ] **Step 6: Commit**

```bash
git add Sources/FlightDeck/Preferences/Preferences.swift \
        Sources/FlightDeck/Preferences/PreferencesStore.swift \
        Tests/FlightDeckTests/PreferencesStoreTests.swift
git commit -m "feat: add the auto-resume preference, off by default"
```

---

### Task 2: Record activity and unread in the snapshot

**Files:**
- Modify: `Sources/FlightDeck/SessionPersistence.swift`
- Modify: `Sources/FlightDeck/SessionStore.swift` (`persist()`, around L494-522)
- Test: `Tests/FlightDeckTests/SessionPersistenceTests.swift`

**Interfaces:**
- Consumes: nothing from Task 1.
- Produces: `SessionSnapshot.Entry.activity: String?` (a `SessionActivity.rawValue`) and `SessionSnapshot.Entry.unread: Bool?`, both written by `SessionStore.persist()`.

- [ ] **Step 1: Write the failing tests**

Append to `Tests/FlightDeckTests/SessionPersistenceTests.swift`, inside the existing class:

```swift
    // MARK: Recorded activity and unread

    /// Snapshots predating these fields must still decode, or the first launch after this
    /// change wipes every tab — the same rule `testV1SnapshotWithoutPinDecodes` pins.
    func testSnapshotWithoutActivityOrUnreadDecodes() throws {
        let id = UUID()
        let json = """
        {"sessions":[{"id":"\(id.uuidString)","title":"a","workingDirectory":"/w"}],\
        "sessionCounter":1}
        """
        let snapshot = try JSONDecoder().decode(SessionSnapshot.self, from: Data(json.utf8))

        XCTAssertEqual(snapshot.sessions.first?.id, id)
        XCTAssertNil(snapshot.sessions.first?.activity)
        XCTAssertNil(snapshot.sessions.first?.unread)
    }

    func testPersistRecordsEachSessionsActivity() {
        let persistence = FakePersistence()
        let store = SessionStore(provider: CapturingProvider(), persistence: persistence)
        let a = store.newSession(in: URL(fileURLWithPath: "/work/foo", isDirectory: true))
        let b = store.newSession(in: URL(fileURLWithPath: "/work/bar", isDirectory: true))

        store.applyRegistryForTesting([
            a.id: SessionStatus(activity: .busy),
            b.id: SessionStatus(activity: .shell),
        ])
        // `applyRegistryForTesting` only sets the map; force a save the way any mutation would.
        store.selectedSessionID = a.id

        let stored = persistence.stored?.sessions ?? []
        XCTAssertEqual(stored.first(where: { $0.id == a.id })?.activity, "busy")
        XCTAssertEqual(stored.first(where: { $0.id == b.id })?.activity, "shell")
    }

    /// A tab with no `claude` registered records no activity. Absent is not the same as
    /// idle, and restore has to be able to tell them apart.
    func testPersistRecordsNoActivityForASessionWithNoStatus() {
        let persistence = FakePersistence()
        let store = SessionStore(provider: CapturingProvider(), persistence: persistence)
        let a = store.newSession(in: URL(fileURLWithPath: "/work/foo", isDirectory: true))

        XCTAssertNil(persistence.stored?.sessions.first(where: { $0.id == a.id })?.activity)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `./scripts/test-unit.sh 2>&1 | tail -40`
Expected: compile failure — `value of type 'SessionSnapshot.Entry' has no member 'activity'`.

- [ ] **Step 3: Add the fields**

In `Sources/FlightDeck/SessionPersistence.swift`, add to `SessionSnapshot.Entry` after
`pinnedConversationID`:

```swift
        /// The session's activity when this snapshot was written, as
        /// `SessionActivity.rawValue`. Absent means no `claude` was registered for this tab
        /// — which is deliberately distinct from `"idle"`, and is what an older snapshot
        /// reads as.
        ///
        /// Optional for the same load-bearing reason as `pinnedConversationID` above.
        var activity: String?
        /// Whether this session finished while the user was looking elsewhere. Absent
        /// reads as false. Optional for the same reason as `activity`.
        var unread: Bool?
```

and extend the memberwise initializer:

```swift
        init(
            id: UUID,
            title: String,
            workingDirectory: String,
            pinnedConversationID: UUID? = nil,
            activity: String? = nil,
            unread: Bool? = nil
        ) {
            self.id = id
            self.title = title
            self.workingDirectory = workingDirectory
            self.pinnedConversationID = pinnedConversationID
            self.activity = activity
            self.unread = unread
        }
```

- [ ] **Step 4: Write them from `persist()`**

In `Sources/FlightDeck/SessionStore.swift`, change the `sessions:` mapping inside
`persist()` to:

```swift
            sessions: repos.flatMap(\.sessions).map {
                .init(
                    id: $0.id,
                    title: $0.title,
                    workingDirectory: $0.workingDirectory,
                    pinnedConversationID: $0.pinnedConversationID,
                    // `nil` rather than a sentinel when no `claude` is registered: restore
                    // has to distinguish "was not running" from "was running and idle".
                    activity: statuses[$0.id]?.activity.rawValue,
                    // `nil` rather than `false` so the common case adds no noise to a file
                    // that is meant to stay readable.
                    unread: unreadIdle.contains($0.id) ? true : nil
                )
            },
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `./scripts/test-unit.sh 2>&1 | tail -20`
Expected: all tests pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/FlightDeck/SessionPersistence.swift \
        Sources/FlightDeck/SessionStore.swift \
        Tests/FlightDeckTests/SessionPersistenceTests.swift
git commit -m "feat: record each session's activity and unread state in the snapshot"
```

---

### Task 3: Persist on a genuine status transition

**Files:**
- Modify: `Sources/FlightDeck/SessionStore.swift` (`applyRegistry`, around L1060-1073)
- Test: `Tests/FlightDeckTests/SessionStoreTests.swift`

**Interfaces:**
- Consumes: `SessionSnapshot.Entry.activity` from Task 2.
- Produces: no new API. `applyRegistry` now calls `persist()` when — and only when — `statuses` changed.

- [ ] **Step 1: Write the failing tests**

Append to `Tests/FlightDeckTests/SessionStoreTests.swift`, inside the existing class. Add
this fake at the top of the class if one is not already present:

```swift
    /// In-memory stand-in for the snapshot store.
    final class FakePersistence: SessionPersisting {
        var stored: SessionSnapshot?
        var saveCount = 0
        func load() -> SessionSnapshot? { stored }
        func save(_ snapshot: SessionSnapshot) { stored = snapshot; saveCount += 1 }
    }
```

Then:

```swift
    // MARK: Persisting status transitions

    /// Recording activity is what makes auto-resume survive a SIGKILL rather than only a
    /// clean quit, so the registry tick has to save — it is the only place activity moves.
    func testRegistryTransitionPersists() {
        let persistence = FakePersistence()
        let store = SessionStore(provider: StubProvider(), persistence: persistence)
        let s = store.newSession(in: URL(fileURLWithPath: "/work/foo", isDirectory: true))
        let before = persistence.saveCount

        store.applyRegistry([1: row(s, activity: .busy)])

        XCTAssertGreaterThan(persistence.saveCount, before)
    }

    /// The counterpart. `applyRegistry` runs on every poll; saving unconditionally would
    /// rewrite sessions.json a few times a second for the life of the app.
    func testRegistryPollWithNoChangeDoesNotPersist() {
        let persistence = FakePersistence()
        let store = SessionStore(provider: StubProvider(), persistence: persistence)
        let s = store.newSession(in: URL(fileURLWithPath: "/work/foo", isDirectory: true))
        let rows = [pid_t(1): row(s, activity: .busy)]

        store.applyRegistry(rows)
        let settled = persistence.saveCount
        store.applyRegistry(rows)

        XCTAssertEqual(persistence.saveCount, settled)
    }
```

Add this helper to the class. It matches the `row(_:pid:cwd:procStart:)` idiom already used
by `ConversationRepinTests` and `SessionProjectMoveTests`:

```swift
    /// A registry row for `session`, in the shape `applyRegistry` resolves against.
    ///
    /// `cwd` must equal the session's own working directory: `applyRegistry` reads a
    /// differing cwd as `claude` having moved the session to another project and calls
    /// `moveSession`, which is not what these tests are exercising.
    private func row(
        _ session: Session, pid: pid_t = 1, activity: SessionActivity
    ) -> ClaudeStatusFile.Entry {
        .init(
            pid: pid,
            sessionID: session.pinnedConversationID,
            activity: activity,
            waitingFor: nil,
            startedAt: 1,
            cwd: session.workingDirectory,
            procStart: "start-a"
        )
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `./scripts/test-unit.sh 2>&1 | tail -40`
Expected: `testRegistryTransitionPersists` fails — `XCTAssertGreaterThan failed`. (If it
fails to compile instead, the `entry` helper's signature is wrong; fix it against
`ClaudeStatusFile.Entry` and re-run before proceeding.)

- [ ] **Step 3: Persist after the transition**

In `applyRegistry`, immediately after the existing `deliverNotifications(...)` call at the
end of the method, add:

```swift
        // Below the `guard next != statuses` above, so this writes only on a real
        // transition — a handful of small atomic writes a minute, not one per poll.
        // Recording activity here rather than at quit is what covers a SIGKILL (which is
        // how scripts/swap-release.sh stops the app) and a panic, and an unplanned exit is
        // the case auto-resume is most wanted for.
        persist()
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `./scripts/test-unit.sh 2>&1 | tail -20`
Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/FlightDeck/SessionStore.swift Tests/FlightDeckTests/SessionStoreTests.swift
git commit -m "feat: persist the snapshot when a session's status actually changes"
```

---

### Task 4: Compute each tick's transitions once

**Files:**
- Modify: `Sources/FlightDeck/SessionStore.swift` (`applyRegistry`, `applyReadState`, `deliverNotifications`)
- Test: existing `SessionStoreTests` / `SessionNotificationPolicyTests` must stay green.

**Interfaces:**
- Consumes: nothing new.
- Produces: `struct StatusTransition { let id: UUID; let old: SessionStatus?; let new: SessionStatus? }` (fileprivate to `SessionStore.swift` is fine), and the reshaped `applyReadState(_ transitions: [StatusTransition])` / `deliverNotifications(_ transitions: [StatusTransition])`. Task 9 adds a third consumer.

This is a pure refactor — no behaviour change, no new test. It exists because three
consumers currently re-derive the same edge from the same two dictionaries, each free to be
wrong on its own (Task 5 fixes one that is). Adding a fourth consumer without this would
compound the problem.

- [ ] **Step 1: Add the transition type**

At the top of `Sources/FlightDeck/SessionStore.swift`, above `final class SessionStore`:

```swift
/// One session's status edge across a single registry tick.
///
/// Three things act on these edges — the unread mark, notifications, and the auto-resume
/// prompt — and each used to re-walk the before/after maps itself. Computing the edges once
/// and handing them out means "what changed" has a single definition. A proper state machine
/// over `SessionActivity` is the next step and is recorded in docs/FOLLOWUPS.md; this is the
/// seam it would slot into.
struct StatusTransition: Equatable {
    let id: UUID
    let old: SessionStatus?
    let new: SessionStatus?
}
```

- [ ] **Step 2: Build them in `applyRegistry`**

Replace the tail of `applyRegistry` (from `let previous = statuses` onward) with:

```swift
        let previous = statuses
        statuses = next
        let transitions = Set(previous.keys).union(next.keys).map {
            StatusTransition(id: $0, old: previous[$0], new: next[$0])
        }
        applyReadState(transitions)
        deliverNotifications(transitions)
        persist()
```

- [ ] **Step 3: Reshape the two consumers**

`applyReadState` becomes:

```swift
    /// One read/unread decision per session, over every edge this tick produced.
    private func applyReadState(_ transitions: [StatusTransition]) {
        let active = appIsActive()
        for transition in transitions {
            switch SessionReadPolicy.change(
                old: transition.old, new: transition.new,
                isViewed: active && selectedSessionID == transition.id
            ) {
            case .none:
                continue
            case .mark:
                unreadIdle.insert(transition.id)
            case .clear:
                unreadIdle.remove(transition.id)
            }
        }

        // A session whose `claude` exited renders no icon at all, so a mark left behind for
        // it could never be seen or cleared. Drop it rather than leak the entry.
        unreadIdle.formIntersection(statuses.keys)
    }
```

`deliverNotifications` becomes:

```swift
    /// One notification decision per session, over every edge this tick produced — so a
    /// session that vanished while waiting still gets its banner withdrawn.
    private func deliverNotifications(_ transitions: [StatusTransition]) {
        guard let notifier else { return }
        let active = appIsActive()
        for transition in transitions {
            switch SessionNotificationPolicy.action(
                old: transition.old, new: transition.new, appActive: active
            ) {
            case .none:
                continue
            case .notify:
                guard let status = transition.new, let title = title(of: transition.id)
                else { continue }
                notifier.notify(sessionID: transition.id, title: title, body: status.tooltip)
            case .withdraw:
                notifier.withdraw(sessionID: transition.id)
            }
        }
    }
```

Note `formIntersection(statuses.keys)` — `statuses` has already been assigned to `next` at
this point, so this preserves the current behaviour exactly. Task 5 replaces that line.

- [ ] **Step 4: Run the full suite to verify nothing changed**

Run: `./scripts/test-unit.sh 2>&1 | tail -20`
Expected: all tests pass, with no test edits. If any test needed changing, the refactor was
not behaviour-preserving — revert and redo it.

- [ ] **Step 5: Commit**

```bash
git add Sources/FlightDeck/SessionStore.swift
git commit -m "refactor: compute each registry tick's status transitions once"
```

---

### Task 5: Fix the unread pruning rule

**Files:**
- Modify: `Sources/FlightDeck/SessionStore.swift` (`applyReadState`, `closeSession`)
- Test: `Tests/FlightDeckTests/SessionStoreTests.swift`

**Interfaces:**
- Consumes: `StatusTransition` from Task 4.
- Produces: no new API. `unreadIdle` now survives ticks in which a session has no registry entry yet.

- [ ] **Step 1: Write the failing tests**

Append to `Tests/FlightDeckTests/SessionStoreTests.swift`:

```swift
    // MARK: Unread pruning

    /// At launch `statuses` is empty until each resumed `claude` re-registers. The old
    /// blanket intersection wiped every restored mark on that first tick, before it had ever
    /// been drawn — SessionStatusIcon renders nothing for a nil status.
    func testAMarkSurvivesATickInWhichTheSessionHasNoStatusYet() {
        let store = SessionStore(provider: StubProvider())
        let s = store.newSession(in: URL(fileURLWithPath: "/work/foo", isDirectory: true))
        store.markUnreadForTesting([s.id])

        store.applyRegistry([:])

        XCTAssertTrue(store.unreadIdle.contains(s.id))
    }

    /// The case the intersection was there for: a session that HAD a status and lost it has
    /// no icon to carry the mark, so the entry must not leak.
    func testAMarkIsDroppedWhenAnExistingStatusDisappears() {
        let store = SessionStore(provider: StubProvider())
        let s = store.newSession(in: URL(fileURLWithPath: "/work/foo", isDirectory: true))
        store.selectedSessionID = nil
        store.appIsActive = { false }

        store.applyRegistry([1: row(s, activity: .busy)])
        store.applyRegistry([1: row(s, activity: .idle)])
        XCTAssertTrue(store.unreadIdle.contains(s.id), "precondition: busy -> idle marks")

        store.applyRegistry([:])

        XCTAssertFalse(store.unreadIdle.contains(s.id))
    }

    func testClosingASessionDropsItsMark() {
        let store = SessionStore(provider: StubProvider())
        let s = store.newSession(in: URL(fileURLWithPath: "/work/foo", isDirectory: true))
        store.markUnreadForTesting([s.id])

        store.closeSession(s.id)

        XCTAssertFalse(store.unreadIdle.contains(s.id))
    }
```

- [ ] **Step 2: Add the test seam**

`unreadIdle` is `private(set)`, so tests cannot seed it. Next to the existing
`applyRegistryForTesting` in `SessionStore.swift` (around L845), add:

```swift
    /// Test seam. Production marks come from `applyReadState` and from restore; a test that
    /// only cares about how a mark is *pruned* should not have to script an edge to create it.
    func markUnreadForTesting(_ ids: Set<UUID>) {
        unreadIdle.formUnion(ids)
    }
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `./scripts/test-unit.sh 2>&1 | tail -40`
Expected: `testAMarkSurvivesATickInWhichTheSessionHasNoStatusYet` and
`testClosingASessionDropsItsMark` fail; the middle one passes.

- [ ] **Step 4: Narrow the pruning rule**

In `applyReadState`, replace the trailing `unreadIdle.formIntersection(statuses.keys)` with:

```swift
        // Prune only what actually went away this tick. A blanket intersection against the
        // live statuses looks equivalent and is not: at launch `statuses` is empty until each
        // resumed `claude` re-registers, so it wiped every mark restore had just seeded — and
        // it did so before any of them had been drawn, since SessionStatusIcon renders
        // nothing for a nil status. A mark for a session that has never had a status is
        // waiting for its process to appear, not stale.
        for transition in transitions where transition.old != nil && transition.new == nil {
            unreadIdle.remove(transition.id)
        }
```

- [ ] **Step 5: Drop the mark on close**

In `closeSession`, immediately after the existing `anchors.removeValue(forKey: id)`:

```swift
        // The blanket intersection in `applyReadState` used to cover this implicitly. Now
        // that it only prunes what it saw disappear, a closed tab has to say so itself —
        // its id is in neither snapshot, so no tick will ever clean it up.
        unreadIdle.remove(id)
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `./scripts/test-unit.sh 2>&1 | tail -20`
Expected: all tests pass.

- [ ] **Step 7: Commit**

```bash
git add Sources/FlightDeck/SessionStore.swift Tests/FlightDeckTests/SessionStoreTests.swift
git commit -m "fix: stop the first registry tick wiping restored unread marks"
```

---

### Task 6: Restore seeds unread marks

**Files:**
- Modify: `Sources/FlightDeck/SessionStore.swift` (`restore`, around L455-478)
- Test: `Tests/FlightDeckTests/SessionPersistenceTests.swift`

**Interfaces:**
- Consumes: `SessionSnapshot.Entry.unread` from Task 2, the pruning fix from Task 5.
- Produces: no new API.

- [ ] **Step 1: Write the failing tests**

Append to `Tests/FlightDeckTests/SessionPersistenceTests.swift`:

```swift
    // MARK: Restoring unread marks

    func testRestoreSeedsUnreadMarks() {
        let unread = UUID()
        let read = UUID()
        let persistence = FakePersistence()
        persistence.stored = SessionSnapshot(
            sessions: [
                .init(id: unread, title: "a", workingDirectory: "/w", unread: true),
                .init(id: read, title: "b", workingDirectory: "/w"),
            ],
            selectedSessionID: nil,
            sessionCounter: 2
        )
        let store = SessionStore(provider: CapturingProvider(), persistence: persistence)

        XCTAssertTrue(store.restore(directoryExists: allDirsExist))

        XCTAssertTrue(store.unreadIdle.contains(unread))
        XCTAssertFalse(store.unreadIdle.contains(read))
    }

    /// The tab you land on is in front of you, so it comes back read. Seeding happens before
    /// the selection is assigned, whose `didSet` clears the mark — and `observeAppActivation`
    /// would clear it a moment later at launch regardless.
    func testTheRestoredSelectionComesBackRead() {
        let selected = UUID()
        let persistence = FakePersistence()
        persistence.stored = SessionSnapshot(
            sessions: [.init(id: selected, title: "a", workingDirectory: "/w", unread: true)],
            selectedSessionID: selected,
            sessionCounter: 1
        )
        let store = SessionStore(provider: CapturingProvider(), persistence: persistence)

        XCTAssertTrue(store.restore(directoryExists: allDirsExist))

        XCTAssertFalse(store.unreadIdle.contains(selected))
    }

    /// A mark for a session whose directory has gone is not restored, because the session
    /// itself is not — there would be no row to draw it on.
    func testAMarkForADroppedSessionIsNotRestored() {
        let gone = UUID()
        let persistence = FakePersistence()
        persistence.stored = SessionSnapshot(
            sessions: [.init(id: gone, title: "a", workingDirectory: "/gone", unread: true)],
            selectedSessionID: nil,
            sessionCounter: 1
        )
        let store = SessionStore(provider: CapturingProvider(), persistence: persistence)

        store.restore(directoryExists: { _ in false })

        XCTAssertFalse(store.unreadIdle.contains(gone))
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `./scripts/test-unit.sh 2>&1 | tail -40`
Expected: `testRestoreSeedsUnreadMarks` fails — `XCTAssertTrue failed`.

- [ ] **Step 3: Seed during pass two**

In `restore()`, inside the `for entry in snapshot.sessions where directoryExists(...)` loop,
after the `insertSession(...)` call, add:

```swift
            // Seeded here rather than after the loop so it covers exactly the sessions that
            // were actually rebuilt — a session whose directory has gone has no row to draw a
            // mark on. Before the `selectedSessionID` assignment below on purpose: its
            // `didSet` clears the mark for the tab you land on, which is correct.
            if entry.unread == true { unreadIdle.insert(entry.id) }
```

- [ ] **Step 4: Correct the stale comment on `unreadIdle`**

The property's doc comment at `SessionStore.swift:47` currently ends with "Not persisted — a
relaunch is not something you need to be told you missed." Replace that sentence with:

```swift
    /// Persisted, as of the auto-resume work: what finished while you were away is exactly
    /// what you want to find when you come back, and quitting for the day is the longest
    /// "away" there is. Written by `persist()`, seeded by `restore()`.
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `./scripts/test-unit.sh 2>&1 | tail -20`
Expected: all tests pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/FlightDeck/SessionStore.swift Tests/FlightDeckTests/SessionPersistenceTests.swift
git commit -m "feat: carry unread marks across a relaunch"
```

---

### Task 7: Extract the shared injector

**Files:**
- Modify: `Sources/FlightDeck/SessionStore.swift` (`flushPendingRename`, around L932-955)
- Test: existing `Tests/FlightDeckTests/SessionRenameTests.swift` must stay green.

**Interfaces:**
- Consumes: nothing new.
- Produces: `@discardableResult private func inject(_ text: String, into id: UUID, stillWanted: @escaping @MainActor () -> Bool, onSent: @escaping @MainActor () -> Void) -> Bool`. Returns `false` when this is a bad moment and nothing was sent; the caller retries on a later tick. Task 9's second call site depends on this exact signature.

Pure refactor — no behaviour change, no new test. The existing rename tests are the
regression guard, and they model the input bar faithfully (`SpyInjector` distinguishes a
kill that lands on a draft from one that lands on a placeholder hint), so they will catch a
mistake here.

- [ ] **Step 1: Add the helper**

In `SessionStore.swift`, directly above `flushPendingRename`:

```swift
    /// Types `text` into a session's input box and submits it, preserving whatever draft was
    /// there. Returns false when this is a bad moment — nothing was sent, and the caller
    /// should leave its request pending and try again on a later tick.
    ///
    /// The gates, and why each one:
    ///
    /// - **Idle only.** While `busy` the text queues behind the running turn; while
    ///   `waiting` a Return answers a permission prompt or dialog instead of submitting;
    ///   `shell` means no `claude` is running at all, so the text would hit a bare shell.
    /// - **One row only.** Ctrl+U kills a single logical line and yank-pop *replaces* rather
    ///   than appends, so a draft spanning rows cannot be taken apart and put back.
    ///
    /// The kill happens *before* we know whether there was anything to kill, because that is
    /// the only way to find out: Claude Code renders its placeholder hint in exactly the same
    /// shape as a real draft (see `InputBar`), so the screen cannot be trusted to say whether
    /// the buffer is empty. Killing and then comparing measures the effect instead. A kill
    /// that changed nothing means the line was empty and there is nothing to restore —
    /// yanking there would paste the user's *previous* kill into the bar.
    ///
    /// The yank comes after the Return, so a wrong guess can only leave text sitting in the
    /// bar, never submit it. `sendText` and `sendReturn` are separate because a paste is not
    /// typing — see `TextInjecting.sendReturn()`.
    ///
    /// `stillWanted` is re-checked after the settle delay, because the request can be
    /// replaced or cancelled while Claude Code repaints. `onSent` runs once the text has been
    /// submitted, and is where the caller retires its pending entry.
    @discardableResult
    private func inject(
        _ text: String,
        into id: UUID,
        stillWanted: @escaping @MainActor () -> Bool,
        onSent: @escaping @MainActor () -> Void
    ) -> Bool {
        guard statuses[id]?.activity == .idle,
              let injector = injector(for: id),
              let viewport = injector.readViewport(),
              let bar = InputBar.read(fromViewport: viewport),
              bar.rows.count == 1
        else { return false }

        let before = bar.content
        injector.sendKillLine()
        // Claude Code needs a moment to repaint before the screen reflects the kill.
        injectionSettle {
            guard stillWanted() else { return }
            let after = injector.readViewport().flatMap(InputBar.read(fromViewport:))?.content
            injector.sendText(text)
            injector.sendReturn()
            // Restore only on a *confirmed* change. If the screen went unreadable we do not
            // know, and the draft is one Ctrl+Y away in Claude's own ring — better than
            // pasting text the user never typed into a bar that was empty.
            if let after, after != before { injector.sendYank() }
            onSent()
        }
        return true
    }
```

- [ ] **Step 2: Rewrite `flushPendingRename` on top of it**

Replace the whole body of `flushPendingRename` (keep its existing doc comment, but move the
paragraphs describing the gates and the kill-then-compare trick up to `inject`, leaving the
rename-specific reasoning behind):

```swift
    private func flushPendingRename(_ id: UUID) {
        guard let name = pendingRenames[id] else { return }
        inject(
            "/rename \(name)",
            into: id,
            // A second rename during the settle window replaces the first; typing the
            // superseded name would be wrong, and typing both in turn worse.
            stillWanted: { [weak self] in
                guard let self else { return false }
                return self.pendingRenames[id] == name
            },
            onSent: { [weak self] in self?.pendingRenames[id] = nil }
        )
    }
```

- [ ] **Step 3: Run the full suite to verify nothing changed**

Run: `./scripts/test-unit.sh 2>&1 | tail -20`
Expected: all tests pass, `SessionRenameTests` included, with no test edits.

- [ ] **Step 4: Commit**

```bash
git add Sources/FlightDeck/SessionStore.swift
git commit -m "refactor: extract the draft-preserving text injector from rename"
```

---

### Task 8: Seed pending resume prompts at restore

**Files:**
- Modify: `Sources/FlightDeck/SessionStore.swift` (`restore`, new stored properties)
- Create: `Tests/FlightDeckTests/SessionAutoResumeTests.swift`

**Interfaces:**
- Consumes: `PreferencesStore.autoResumesRunningSessions` (Task 1), `SessionSnapshot.Entry.activity` (Task 2).
- Produces: `SessionStore.pendingResumePrompts: [UUID: Date]` (internal, so tests can read it), `SessionStore.now: () -> Date` test seam, `static let resumePrompt = "Keep going"`, `static let resumePromptWindow: TimeInterval = 120`, `static let resumableActivities: Set<SessionActivity> = [.busy, .shell]`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/FlightDeckTests/SessionAutoResumeTests.swift`:

```swift
import XCTest
@testable import FlightDeck

@MainActor
final class SessionAutoResumeTests: XCTestCase {
    final class StubProvider: SurfaceProvider {
        func makeSurface(_ config: Ghostty.SurfaceConfiguration) -> Ghostty.SurfaceView? { nil }
        func tick() {}
    }

    final class FakePersistence: SessionPersisting {
        var stored: SessionSnapshot?
        func load() -> SessionSnapshot? { stored }
        func save(_ snapshot: SessionSnapshot) { stored = snapshot }
    }

    final class MemoryPreferences: PreferencesPersisting {
        var stored: Preferences?
        func load() -> Preferences? { stored }
        func save(_ preferences: Preferences) { stored = preferences }
    }

    private let allDirsExist: (String) -> Bool = { _ in true }

    private func preferences(autoResume: Bool) -> PreferencesStore {
        let store = PreferencesStore(persistence: MemoryPreferences())
        store.autoResumesRunningSessions = autoResume
        return store
    }

    /// A snapshot with one session per activity, so a single restore exercises the whole
    /// rule. Returns the ids in the order the activities were given.
    private func snapshot(activities: [String?]) -> (SessionSnapshot, [UUID]) {
        let ids = activities.map { _ in UUID() }
        let entries = zip(ids, activities).map { id, activity in
            SessionSnapshot.Entry(
                id: id, title: "s", workingDirectory: "/w", activity: activity
            )
        }
        return (
            SessionSnapshot(sessions: entries, selectedSessionID: nil, sessionCounter: ids.count),
            ids
        )
    }

    /// Named `makeStore` rather than `store` because every caller binds the result to a
    /// local `store`, and `let store = store(…)` is "variable used within its own initial
    /// value". Matches the `makeStore()` idiom in ConversationRepinTests.
    private func makeStore(
        _ snapshot: SessionSnapshot, autoResume: Bool
    ) -> SessionStore {
        let persistence = FakePersistence()
        persistence.stored = snapshot
        return SessionStore(
            provider: StubProvider(),
            persistence: persistence,
            preferences: preferences(autoResume: autoResume)
        )
    }

    // MARK: Seeding

    func testBusyAndShellSessionsArePendingWhenThePreferenceIsOn() {
        let (snap, ids) = snapshot(activities: ["busy", "shell"])
        let store = makeStore(snap, autoResume: true)

        XCTAssertTrue(store.restore(directoryExists: allDirsExist))

        XCTAssertNotNil(store.pendingResumePrompts[ids[0]])
        XCTAssertNotNil(store.pendingResumePrompts[ids[1]])
    }

    /// `waiting` is excluded deliberately: whatever the session was blocked on does not
    /// survive the restart, so "Keep going" would answer a question that no longer exists.
    func testIdleWaitingAndUnrecordedSessionsAreNotPending() {
        let (snap, ids) = snapshot(activities: ["idle", "waiting", nil])
        let store = makeStore(snap, autoResume: true)

        store.restore(directoryExists: allDirsExist)

        for id in ids { XCTAssertNil(store.pendingResumePrompts[id]) }
    }

    func testNothingIsPendingWhenThePreferenceIsOff() {
        let (snap, ids) = snapshot(activities: ["busy", "shell"])
        let store = makeStore(snap, autoResume: false)

        store.restore(directoryExists: allDirsExist)

        for id in ids { XCTAssertNil(store.pendingResumePrompts[id]) }
    }

    func testASessionWhoseDirectoryIsGoneIsNotPending() {
        let (snap, ids) = snapshot(activities: ["busy"])
        let store = makeStore(snap, autoResume: true)

        store.restore(directoryExists: { _ in false })

        XCTAssertNil(store.pendingResumePrompts[ids[0]])
    }

    func testTheDeadlineIsOneWindowFromRestore() {
        let (snap, ids) = snapshot(activities: ["busy"])
        let store = makeStore(snap, autoResume: true)
        let start = Date(timeIntervalSince1970: 1_000_000)
        store.now = { start }

        store.restore(directoryExists: allDirsExist)

        XCTAssertEqual(
            store.pendingResumePrompts[ids[0]],
            start.addingTimeInterval(SessionStore.resumePromptWindow)
        )
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `./scripts/test-unit.sh 2>&1 | tail -40`
Expected: compile failure — `value of type 'SessionStore' has no member 'pendingResumePrompts'`.

- [ ] **Step 3: Add the state and the seams**

In `SessionStore.swift`, near the other pending state (`pendingRenames`, around L157):

```swift
    /// Sessions restored from a snapshot that recorded them working, each mapped to the
    /// instant its prompt stops being worth sending. Drained by `flushPendingResumePrompts`
    /// on the registry tick, because a resumed `claude` takes seconds to boot and there is
    /// nothing to type into until it does.
    ///
    /// Internal rather than private so the tests can observe the queue without scripting a
    /// whole surface; nothing outside this type writes it.
    private(set) var pendingResumePrompts: [UUID: Date] = [:]

    /// Test seam, in the style of `appIsActive` and `injectionSettle`. Production reads the
    /// wall clock.
    var now: () -> Date = { Date() }
```

and near the other type-level constants:

```swift
    /// What a resumed session is told. A constant rather than a preference: if the fixed
    /// string turns out to be wrong in practice, making it configurable is a smaller change
    /// than un-shipping a setting nobody wanted.
    static let resumePrompt = "Keep going"

    /// How long after a restore a pending prompt is still worth sending. Without a deadline
    /// an entry that never met its gates would sit in the queue and fire hours later, into a
    /// session the user has long since been working in.
    static let resumePromptWindow: TimeInterval = 120

    /// The activities that mean "this session was working when we went away". `waiting` is
    /// excluded: what it was blocked on does not survive the restart.
    static let resumableActivities: Set<SessionActivity> = [.busy, .shell]
```

- [ ] **Step 4: Seed during pass two of `restore`**

At the top of `restore()`, after the `sessionCounter` assignment:

```swift
        // One deadline for the whole restore, not one per session: they all resume together,
        // and staggering them by loop position would be noise.
        let autoResume = preferences?.autoResumesRunningSessions ?? false
        let promptDeadline = now().addingTimeInterval(Self.resumePromptWindow)
```

and inside the pass-two loop, next to the `unreadIdle` seeding from Task 6:

```swift
            if autoResume,
               let activity = entry.activity.flatMap(SessionActivity.init(rawValue:)),
               Self.resumableActivities.contains(activity) {
                pendingResumePrompts[entry.id] = promptDeadline
            }
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `./scripts/test-unit.sh 2>&1 | tail -20`
Expected: all tests pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/FlightDeck/SessionStore.swift Tests/FlightDeckTests/SessionAutoResumeTests.swift
git commit -m "feat: queue a resume prompt for sessions that were working at shutdown"
```

---

### Task 9: Deliver, cancel, and expire the resume prompt

**Files:**
- Modify: `Sources/FlightDeck/SessionStore.swift` (`applyRegistry`, new `flushPendingResumePrompts` / `cancelSupersededPrompts`)
- Test: `Tests/FlightDeckTests/SessionAutoResumeTests.swift`

**Interfaces:**
- Consumes: `inject(_:into:stillWanted:onSent:)` (Task 7), `StatusTransition` (Task 4), `pendingResumePrompts` / `now` / `resumePrompt` (Task 8).
- Produces: no new public API.

- [ ] **Step 1: Write the failing tests**

Append to `Tests/FlightDeckTests/SessionAutoResumeTests.swift`. Reuse the spy from the
rename tests by copying it in — it models the input bar rather than just recording against
it, which is what makes the empty-vs-draft cases meaningful:

```swift
    // MARK: Delivery

    /// Same spy as SessionRenameTests: it models Claude Code's input box, so a kill that
    /// lands on a draft clears it and a kill that lands on a placeholder hint does not.
    final class SpyInjector: TextInjecting {
        enum Event: Equatable { case text(String), ret, killLine, yank }
        var events: [Event] = []
        var sent: [String] {
            events.compactMap { if case .text(let t) = $0 { return t } else { return nil } }
        }
        var buffer = ""
        var renderedRows: [String] = ["❯"]
        var viewportIsReadable = true

        func sendText(_ text: String) { events.append(.text(text)) }
        func sendReturn() { events.append(.ret) }
        func sendKillLine() {
            events.append(.killLine)
            guard !buffer.isEmpty else { return }
            buffer = ""
            renderedRows = ["❯"]
        }
        func sendYank() { events.append(.yank) }
        func readViewport() -> String? {
            guard viewportIsReadable else { return nil }
            let rule = String(repeating: "─", count: 92)
            return ([rule] + renderedRows + [rule, "  Opus 5 (1M context)  ⎇ master"])
                .joined(separator: "\n")
        }
    }

    /// Restores one busy session, wires a spy to it, and runs the settle callback inline so
    /// the test does not have to wait on a real repaint delay.
    private func restoredSession(
        autoResume: Bool = true
    ) -> (store: SessionStore, id: UUID, spy: SpyInjector) {
        let (snap, ids) = snapshot(activities: ["busy"])
        let store = makeStore(snap, autoResume: autoResume)
        let spy = SpyInjector()
        store.injectorOverride = spy
        store.injectionSettle = { work in work() }
        store.restore(directoryExists: allDirsExist)
        return (store, ids[0], spy)
    }

    func testThePromptIsSentOnceTheSessionLandsIdle() {
        let (store, id, spy) = restoredSession()

        store.applyRegistryForTesting([id: SessionStatus(activity: .idle)])
        store.flushPendingResumePromptsForTesting()

        XCTAssertEqual(spy.sent, ["Keep going"])
        XCTAssertEqual(spy.events.last, .ret, "Return must arrive after the paste closes")
        XCTAssertNil(store.pendingResumePrompts[id], "one-shot")
    }

    func testNothingIsSentWhileTheSessionIsStillBooting() {
        let (store, id, spy) = restoredSession()

        // No status at all yet: `claude` has not registered.
        store.flushPendingResumePromptsForTesting()

        XCTAssertTrue(spy.sent.isEmpty)
        XCTAssertNotNil(store.pendingResumePrompts[id], "still pending, not dropped")
    }

    func testThePromptIsSentOnlyOnce() {
        let (store, id, spy) = restoredSession()
        store.applyRegistryForTesting([id: SessionStatus(activity: .idle)])

        store.flushPendingResumePromptsForTesting()
        store.flushPendingResumePromptsForTesting()

        XCTAssertEqual(spy.sent, ["Keep going"])
    }

    /// Something is already working in there, so there is nothing to keep going about.
    func testReachingBusyBeforeTheFlushCancelsThePrompt() {
        let (store, id, spy) = restoredSession()

        store.cancelSupersededPromptsForTesting([
            StatusTransition(id: id, old: nil, new: SessionStatus(activity: .busy))
        ])
        store.applyRegistryForTesting([id: SessionStatus(activity: .idle)])
        store.flushPendingResumePromptsForTesting()

        XCTAssertTrue(spy.sent.isEmpty)
        XCTAssertNil(store.pendingResumePrompts[id])
    }

    func testReachingWaitingBeforeTheFlushCancelsThePrompt() {
        let (store, id, spy) = restoredSession()

        store.cancelSupersededPromptsForTesting([
            StatusTransition(id: id, old: nil, new: SessionStatus(activity: .waiting))
        ])
        store.applyRegistryForTesting([id: SessionStatus(activity: .idle)])
        store.flushPendingResumePromptsForTesting()

        XCTAssertTrue(spy.sent.isEmpty)
    }

    /// The staleness guard: a prompt that never met its gates must not fire an hour later
    /// into a session the user has since been working in.
    func testAPromptPastItsDeadlineIsDroppedUnsent() {
        let (snap, ids) = snapshot(activities: ["busy"])
        let store = makeStore(snap, autoResume: true)
        let spy = SpyInjector()
        store.injectorOverride = spy
        store.injectionSettle = { work in work() }
        let start = Date(timeIntervalSince1970: 1_000_000)
        store.now = { start }
        store.restore(directoryExists: allDirsExist)

        store.now = { start.addingTimeInterval(SessionStore.resumePromptWindow + 1) }
        store.applyRegistryForTesting([ids[0]: SessionStatus(activity: .idle)])
        store.flushPendingResumePromptsForTesting()

        XCTAssertTrue(spy.sent.isEmpty)
        XCTAssertNil(store.pendingResumePrompts[ids[0]])
    }

    /// Both want the same input box, and a rename is a direct user action.
    func testAPendingRenameTakesPrecedence() {
        let (store, id, spy) = restoredSession()
        store.applyRegistryForTesting([id: SessionStatus(activity: .idle)])

        store.rename(id, to: "renamed")

        XCTAssertEqual(spy.sent, ["/rename renamed"])
        XCTAssertNotNil(store.pendingResumePrompts[id], "deferred, not dropped")
    }
```

- [ ] **Step 2: Add the test seams**

Next to `applyRegistryForTesting` in `SessionStore.swift`:

```swift
    /// Test seams. Production drives both from `applyRegistry`; a test that only cares about
    /// the prompt queue should not have to fabricate registry rows.
    func flushPendingResumePromptsForTesting() { flushPendingResumePrompts() }
    func cancelSupersededPromptsForTesting(_ transitions: [StatusTransition]) {
        cancelSupersededPrompts(transitions)
    }
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `./scripts/test-unit.sh 2>&1 | tail -40`
Expected: compile failure — `value of type 'SessionStore' has no member 'flushPendingResumePrompts'`.

- [ ] **Step 4: Implement the flush and the cancel**

In `SessionStore.swift`, below `flushPendingRenames`:

```swift
    /// Types "Keep going" into every restored session that is finally ready for it.
    ///
    /// Driven by the registry scan for the same reason the rename retry is: a resumed
    /// `claude` needs seconds to boot, and until it registers there is nothing to type into.
    /// A tab that is not ready stays queued and is tried again on the next tick.
    private func flushPendingResumePrompts() {
        let deadline = now()
        for (id, expiry) in pendingResumePrompts {
            guard deadline < expiry else {
                // Dropped unsent. See `resumePromptWindow`.
                pendingResumePrompts.removeValue(forKey: id)
                continue
            }
            // A rename is a direct user action and wants the same input box. It will clear
            // itself within a tick or two, and this is queued anyway.
            guard pendingRenames[id] == nil else { continue }
            inject(
                Self.resumePrompt,
                into: id,
                // Cancelled during the settle window — the session started working on its
                // own, or the deadline passed on another path.
                stillWanted: { [weak self] in self?.pendingResumePrompts[id] != nil },
                onSent: { [weak self] in self?.pendingResumePrompts.removeValue(forKey: id) }
            )
        }
    }

    /// Drops a queued prompt for any session that has started working on its own.
    ///
    /// Covers both the user getting there first and a resumed `claude` picking its own turn
    /// back up: either way something is already in flight, and "Keep going" would be a second
    /// instruction on top of it. Conservative on purpose — a session that flickers through
    /// `busy` while booting loses its prompt, which is a silent no-op rather than a stray
    /// message typed into someone's work.
    private func cancelSupersededPrompts(_ transitions: [StatusTransition]) {
        guard !pendingResumePrompts.isEmpty else { return }
        for transition in transitions {
            switch transition.new?.activity {
            case .busy, .waiting:
                pendingResumePrompts.removeValue(forKey: transition.id)
            case .idle, .shell, nil:
                continue
            }
        }
    }
```

- [ ] **Step 5: Wire them into `applyRegistry`**

Add the cancel to the transition consumers (after `deliverNotifications(transitions)`, before
`persist()`):

```swift
        cancelSupersededPrompts(transitions)
```

and add the flush to the existing `defer` at the top of `applyRegistry`, alongside the
rename retry:

```swift
        defer {
            flushPendingRenames()
            // Same reason as the line above: this is the retry tick, and a prompt usually
            // waits on a `claude` that has not finished booting — which is not a status
            // change, so gating the retry on one would strand it.
            flushPendingResumePrompts()
        }
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `./scripts/test-unit.sh 2>&1 | tail -20`
Expected: all tests pass.

- [ ] **Step 7: Commit**

```bash
git add Sources/FlightDeck/SessionStore.swift Tests/FlightDeckTests/SessionAutoResumeTests.swift
git commit -m "feat: prompt resumed sessions to keep going once they settle"
```

---

### Task 10: The preference UI

**Files:**
- Modify: `Sources/FlightDeck/Preferences/UI/FlagEditor.swift`
- Modify: `Sources/FlightDeck/Preferences/UI/ClaudeSettingsTab.swift`
- Test: none automated — verified by build plus a read of the rendered tab.

**Interfaces:**
- Consumes: `PreferencesStore.autoResumesRunningSessions` (Task 1).
- Produces: `FlagEditor.header: (() -> AnyView)?`, defaulting to `nil`.

`ClaudeSettingsTab` is today *only* a `FlagEditor`, and `FlagEditor` owns its own `Form`.
Stacking a second grouped `Form` above it needs a hard-coded height and reads badly, so the
toggle goes in as a leading `Section` **inside** the existing Form. `AnyView` rather than a
generic `Header: View` parameter: one static section makes the erasure free, and it keeps
the `ProjectsSettingsTab` call site compiling untouched.

- [ ] **Step 1: Add the header slot**

In `FlagEditor.swift`, add a stored property after `lockedPrefix`:

```swift
    /// Rendered as a leading `Section` inside this view's `Form`. The Claude tab uses it for
    /// settings that belong on that tab but not to the flag model; the Projects tab passes
    /// nothing. `AnyView` rather than a generic parameter because it is one static section,
    /// and a generic would ripple through every call site for no benefit.
    var header: (() -> AnyView)?
```

Then, as the first thing inside the `Form { ... }` in `body`:

```swift
                if let header { header() }
```

Confirm the existing `FlagEditor(flags:inherited:lockedPrefix:)` call in
`ProjectsSettingsTab.swift` still compiles unchanged. If the synthesized memberwise
initializer does not accommodate the new property, add an explicit `init` that defaults
`header` to `nil` rather than editing the Projects call site.

- [ ] **Step 2: Add the toggle**

Replace the `body` of `ClaudeSettingsTab.swift` with:

```swift
    var body: some View {
        FlagEditor(
            flags: $preferences.preferences.globalFlags,
            inherited: nil,
            lockedPrefix: Self.placeholderPrefix,
            header: {
                AnyView(
                    Section("Startup") {
                        Toggle(
                            "Auto-resume running sessions on restart",
                            isOn: Binding(
                                get: { preferences.autoResumesRunningSessions },
                                set: { preferences.autoResumesRunningSessions = $0 }
                            )
                        )
                        .accessibilityIdentifier("prefs-auto-resume")
                        // States the busy/shell rule in the user's terms: "running" is not
                        // self-evident from the label, and the exclusions are the surprising
                        // half.
                        Text("Sessions that were working when Flight Deck last quit are asked to continue once they have resumed. Sessions that were idle, or waiting on you, are left alone.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                )
            }
        )
    }
```

Keep the existing `placeholderPrefix` static property and its doc comment as they are.

- [ ] **Step 3: Verify it builds and the suite is still green**

Run: `./scripts/test-unit.sh 2>&1 | tail -20`
Expected: builds clean, all tests pass.

- [ ] **Step 4: Commit**

```bash
git add Sources/FlightDeck/Preferences/UI/FlagEditor.swift \
        Sources/FlightDeck/Preferences/UI/ClaudeSettingsTab.swift
git commit -m "feat: expose the auto-resume toggle on the Claude tab"
```

---

### Task 11: Record the follow-ups

**Files:**
- Modify: `docs/FOLLOWUPS.md`

**Interfaces:** none.

- [ ] **Step 1: Add the section**

Append a new section to `docs/FOLLOWUPS.md`, matching the file's existing dated-section
style:

```markdown
## From auto-resume & persisted unread (2026-08-15)

- **Status transitions want a state machine.** `applyRegistry` now computes each tick's
  edges once as `[StatusTransition]` and hands them to three consumers — `applyReadState`,
  `deliverNotifications`, and `cancelSupersededPrompts`. That is a seam, not a solution:
  each consumer still decides for itself what a given edge means, and the decisions are
  entangled (a `nil -> idle` edge is "launching" to the read policy and "ready" to the
  prompt queue). The motivating evidence is the bug fixed on that branch: `applyReadState`
  pruned marks with `unreadIdle.formIntersection(current.keys)`, which is correct for a
  session whose `claude` exited and wrong for one whose `claude` has not started yet — the
  two are indistinguishable in that formulation. A small explicit machine over
  `SessionActivity` (states, permitted edges, and what each edge means to each consumer)
  would make that class of bug unrepresentable. Not done on that branch because it touches
  every status consumer at once and the feature did not need it.

- **A prompt can be cancelled by a boot flicker.** `cancelSupersededPrompts` drops a queued
  "Keep going" the moment a session reports `busy` or `waiting`, so a resumed `claude` that
  passes briefly through `busy` while loading its transcript loses its prompt. Deliberately
  conservative: the failure is a silent no-op, where the alternative failure is typing into
  work the user is already doing. If it proves common in practice, the fix is to ignore
  transitions until the session has been seen `idle` at least once — not to remove the
  cancel.

- **Two ticks inside one settle window could double-inject.** `inject` clears the caller's
  pending entry in `onSent`, which runs after the ~120 ms settle delay, so a second registry
  tick arriving inside that window would start a second injection for the same tab. This is
  pre-existing behaviour inherited from `flushPendingRename`, not new to the prompt queue,
  and the registry poll interval is comfortably longer than the settle. Fix by marking
  in-flight at the start of `inject` rather than at completion, if it is ever observed.
```

- [ ] **Step 2: Commit**

```bash
git add docs/FOLLOWUPS.md
git commit -m "docs: record the state-machine follow-up and two accepted prompt limitations"
```

---

### Task 12: ⌘W closes the session, not the window

**Unrelated to auto-resume** — folded into this plan because it was asked for as follow-on
work in the same sitting. It depends on nothing above and nothing above depends on it.

**Files:**
- Modify: `Sources/FlightDeck/TerminalPane.swift`
- Test: none automated. See Step 4.

**Interfaces:**
- Consumes: `SessionStore.closeSession(_:)`, `SessionStore.selectedSessionID` — both already exist.
- Produces: `TerminalHostView.onCloseSession: (() -> Void)?`.

**Why it currently closes the window.** Ghostty's macOS defaults bind `cmd+w` to
`close_surface`, registered *consumed* and not *performable* — exactly the shape
`MenuKeyEquivalents.shouldOfferToMenu` hands to the main menu before the terminal. The menu's
standard File ▸ Close item claims it, and that item's action is `performClose:` on the
window.

**Why the responder chain rather than menu surgery.** That Close item is nil-targeted, so
AppKit sends `performClose:` up the *key window's* responder chain — first responder (the
Ghostty surface) → its superviews → `TerminalHostView` → the content view → the window.
Answering it on `TerminalHostView` therefore intercepts ⌘W and File ▸ Close, while leaving
two things correct for free, with no special-casing:

- The **Settings window** has no `TerminalHostView` in its chain, so ⌘W there still closes
  Settings. A global ⌘W menu item added via `CommandGroup` would have closed a session from
  the Preferences window instead — the reason that simpler approach is wrong.
- The **red traffic-light button** messages `performClose:` to the window directly rather
  than through the chain, so it still closes the window.

With no session selected, `RootView` renders `ContentUnavailableView` instead of
`TerminalPane`, so there is no `TerminalHostView` in the chain at all and ⌘W falls through to
the window — which, under `applicationShouldTerminateAfterLastWindowClosed`, quits. That is
the right fallback and needs no code.

- [ ] **Step 1: Answer `performClose:` on the host view**

In `Sources/FlightDeck/TerminalPane.swift`, extend `TerminalHostView`:

```swift
final class TerminalHostView: NSView {
    var onResize: ((CGSize) -> Void)?

    /// Set by `TerminalPane` on every update. Non-nil means there is a session here to
    /// close; nil means this view should let `performClose:` continue up to the window.
    var onCloseSession: (() -> Void)?

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        onResize?(newSize)
    }

    /// ⌘W and File ▸ Close mean "close this session", not "close the window".
    ///
    /// Declared rather than overridden: `NSView` does not define `performClose(_:)`, and
    /// responder-chain dispatch is by selector lookup, not by inheritance. There is
    /// correspondingly no `super` to call — declining the action is done by failing
    /// validation below, which makes AppKit keep walking the chain to the window.
    @objc func performClose(_ sender: Any?) {
        onCloseSession?()
    }
}

/// Without this, AppKit would treat this view as the handler for `performClose:` even when
/// there is no session behind it, and ⌘W would silently do nothing instead of closing the
/// window.
extension TerminalHostView: NSUserInterfaceValidations {
    func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        guard item.action == #selector(performClose(_:)) else { return true }
        return onCloseSession != nil
    }
}
```

- [ ] **Step 2: Wire it from `TerminalPane`**

In `updateNSView`, alongside the existing surface re-parenting, keep the closure pointing at
whatever is currently selected. Add this immediately after the
`let current = store.selectedSessionID.flatMap { store.surface(for: $0) }` line:

```swift
        // Refreshed on every update, not just on attach: `updateNSView` is the only place
        // that learns about a selection change, and a stale capture here would close the
        // previously-selected session.
        container.onCloseSession = store.selectedSessionID.map { id in
            { [weak store] in store?.closeSession(id) }
        }
```

- [ ] **Step 3: Build**

Run: `./scripts/test-unit.sh 2>&1 | tail -20`
Expected: builds clean, all tests still pass. (No new tests — the behaviour is AppKit
responder-chain dispatch, which is not reachable from the headless unit bundle.)

- [ ] **Step 4: Hand the manual check to the user**

There is no automated coverage for this one, and `scripts/smoke.sh` is off-limits (it steals
focus for ~40 s). Do **not** launch or install the app to verify. Report to the user that
Task 12 needs a manual check in a real build, and list exactly what to try:

1. ⌘W with a session selected → that session's row disappears; the window stays.
2. ⌘W with the Preferences window focused → Preferences closes, no session is touched.
3. The red traffic-light button → the window closes as before.
4. ⌘W with no sessions left → the window closes.

- [ ] **Step 5: Commit**

```bash
git add Sources/FlightDeck/TerminalPane.swift
git commit -m "feat: make Cmd-W and File > Close close the session, not the window"
```

---

## Final verification

- [ ] **Run the whole unit suite one more time**

Run: `./scripts/test-unit.sh 2>&1 | tail -20`
Expected: `Executed N tests, with 0 failures`. Report the actual number.

- [ ] **Confirm the default is genuinely off**

Run: `rg -n "autoResumeRunningSessions" Sources/`
Expected: the initializer defaults it to `false`, and `PreferencesStore.autoResumesRunningSessions`'s getter falls back to `false` when `preferences.claude` is nil. Both, not one.

- [ ] **Confirm no `git add -A` slipped in**

Run: `git status --short`
Expected: any pre-existing untracked files from other sessions (`AGENTS.md`,
`docs/AGENT-OPERATIONS.md`, `docs/CONVENTIONS.md`, a modified `docs/README.md`) are still
there, untouched and uncommitted. This is a shared working copy.
