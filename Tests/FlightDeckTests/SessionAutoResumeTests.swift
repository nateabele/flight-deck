import XCTest
@testable import FlightDeck

@MainActor
final class SessionAutoResumeTests: XCTestCase {
    final class StubProvider: SurfaceProvider {
        func makeSurface(_ config: Ghostty.SurfaceConfiguration) -> Ghostty.SurfaceView? { nil }
        func tick() {}
        var defaultFontSize: Float { 12 }
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

        XCTAssertNotNil(store.pendingPrompts[ids[0]])
        XCTAssertNotNil(store.pendingPrompts[ids[1]])
    }

    /// `waiting` is excluded deliberately: whatever the session was blocked on does not
    /// survive the restart, so "Keep going" would answer a question that no longer exists.
    func testIdleWaitingAndUnrecordedSessionsAreNotPending() {
        let (snap, ids) = snapshot(activities: ["idle", "waiting", nil])
        let store = makeStore(snap, autoResume: true)

        store.restore(directoryExists: allDirsExist)

        for id in ids { XCTAssertNil(store.pendingPrompts[id]) }
    }

    func testNothingIsPendingWhenThePreferenceIsOff() {
        let (snap, ids) = snapshot(activities: ["busy", "shell"])
        let store = makeStore(snap, autoResume: false)

        store.restore(directoryExists: allDirsExist)

        for id in ids { XCTAssertNil(store.pendingPrompts[id]) }
    }

    func testASessionWhoseDirectoryIsGoneIsNotPending() {
        let (snap, ids) = snapshot(activities: ["busy"])
        let store = makeStore(snap, autoResume: true)

        store.restore(directoryExists: { _ in false })

        XCTAssertNil(store.pendingPrompts[ids[0]])
    }

    func testTheDeadlineIsOneWindowFromRestore() {
        let (snap, ids) = snapshot(activities: ["busy"])
        let store = makeStore(snap, autoResume: true)
        let start = Date(timeIntervalSince1970: 1_000_000)
        store.now = { start }

        store.restore(directoryExists: allDirsExist)

        XCTAssertEqual(
            store.pendingPrompts[ids[0]]?.deadline,
            start.addingTimeInterval(SessionStore.resumePromptWindow)
        )
    }

    /// Pins "once per restore", not "once per session". A constant `now` stub cannot tell the
    /// two apart: it returns the same instant however many times it is called, so a regression
    /// that moved the deadline computation inside the pass-two loop would still pass. This uses
    /// an advancing clock and asserts every session got the FIRST reading.
    func testTheDeadlineIsComputedOnceForTheWholeRestore() {
        let (snap, ids) = snapshot(activities: ["busy", "shell"])
        let store = makeStore(snap, autoResume: true)
        let start = Date(timeIntervalSince1970: 1_000_000)
        var calls = 0
        store.now = {
            calls += 1
            return start.addingTimeInterval(Double(calls - 1) * 60)
        }

        store.restore(directoryExists: allDirsExist)

        let expected = start.addingTimeInterval(SessionStore.resumePromptWindow)
        XCTAssertEqual(store.pendingPrompts[ids[0]]?.deadline, expected)
        XCTAssertEqual(store.pendingPrompts[ids[1]]?.deadline, expected)
        XCTAssertEqual(store.pendingPrompts[ids[0]]?.text, SessionStore.resumePrompt)
    }

    // MARK: Delivery

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
        XCTAssertNil(store.pendingPrompts[id], "one-shot")
    }

    func testNothingIsSentWhileTheSessionIsStillBooting() {
        let (store, id, spy) = restoredSession()

        // No status at all yet: `claude` has not registered.
        store.flushPendingResumePromptsForTesting()

        XCTAssertTrue(spy.sent.isEmpty)
        XCTAssertNotNil(store.pendingPrompts[id], "still pending, not dropped")
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
        XCTAssertNil(store.pendingPrompts[id])
    }

    func testReachingWaitingBeforeTheFlushCancelsThePrompt() {
        let (store, id, spy) = restoredSession()

        store.cancelSupersededPromptsForTesting([
            StatusTransition(id: id, old: nil, new: SessionStatus(activity: .waiting))
        ])
        store.applyRegistryForTesting([id: SessionStatus(activity: .idle)])
        store.flushPendingResumePromptsForTesting()

        XCTAssertTrue(spy.sent.isEmpty)
        XCTAssertNil(store.pendingPrompts[id])
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
        XCTAssertNil(store.pendingPrompts[ids[0]])
    }

    /// Both want the same input box, and a rename is a direct user action.
    func testAPendingRenameTakesPrecedence() {
        let (store, id, spy) = restoredSession()
        store.applyRegistryForTesting([id: SessionStatus(activity: .idle)])

        // Defer the rename's own settle so `pendingRenames[id]` is still set at the moment
        // the resume-prompt drain runs. `restoredSession` wires a synchronous settle, so
        // without this override `rename` would complete and clear its own entry before the
        // drain below ever executes, leaving the precedence guard nothing to guard against.
        var renameSettle: (() -> Void)?
        store.injectionSettle = { work in renameSettle = work }
        store.rename(id, to: "renamed")
        XCTAssertNotNil(renameSettle, "the rename must still be mid-flight")

        store.flushPendingResumePromptsForTesting()
        XCTAssertTrue(spy.sent.isEmpty, "neither the rename nor the prompt has landed yet")

        renameSettle?()   // let the rename complete

        XCTAssertEqual(
            spy.sent, ["/rename renamed"], "a second injection must not be allowed to start"
        )
        XCTAssertNotNil(store.pendingPrompts[id], "deferred, not dropped")
    }

    /// The other direction from the precedence test above: the prompt starts first and
    /// leaves its settle outstanding, then a rename lands on the user's keystroke — with no
    /// interval to race against, unlike the registry tick's poll. The in-flight guard inside
    /// `inject` must refuse the second call regardless of which caller goes first.
    func testASecondInjectionIsRefusedWhileTheFirstIsInFlight() {
        let (store, id, spy) = restoredSession()
        store.applyRegistryForTesting([id: SessionStatus(activity: .idle)])

        // Capture the prompt's settle without running it, so its injection stays in flight.
        var promptSettle: (() -> Void)?
        store.injectionSettle = { work in promptSettle = work }
        store.flushPendingResumePromptsForTesting()
        XCTAssertNotNil(promptSettle, "the prompt must still be mid-flight")
        XCTAssertEqual(spy.events, [.killLine], "the prompt's Ctrl+U must have gone out")

        // The user renames while that settle is still pending.
        store.rename(id, to: "renamed")

        XCTAssertEqual(
            spy.events, [.killLine],
            "a second injection must not send its own Ctrl+U while the first is in flight"
        )
    }

    // MARK: Quitting

    private var tmp: URL { URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true) }

    private func entry(_ sessionID: UUID, _ activity: SessionActivity) -> ClaudeStatusFile.Entry {
        .init(pid: 1, sessionID: sessionID, activity: activity, waitingFor: nil,
              startedAt: 1, cwd: tmp.path, procStart: "start-a")
    }

    /// The clean-quit race: reaping kills every `claude` while the status watcher is still
    /// running, so a final tick sees an empty registry. Without the terminating guard that
    /// tick prunes every unread mark and persists `activity: nil` for every tab — wiping
    /// exactly what the next launch needs.
    func testAQuitTimeEmptyTickDoesNotWipeRecordedState() async {
        let persistence = FakePersistence()
        let store = SessionStore(provider: StubProvider(), persistence: persistence)
        store.titleResolver = { _, _, done in done(nil) }
        // Never viewed, so the busy -> idle transition below marks unread rather than
        // clearing it — `appIsActive` alone decides that, independent of the selection.
        store.appIsActive = { false }
        let session = store.newSession(in: tmp)

        // Busy, then idle while unwatched (marks unread), then busy again — a restored,
        // unread, busy session, exactly the state auto-resume depends on.
        store.applyRegistry([1: entry(session.id, .busy)])
        store.applyRegistry([1: entry(session.id, .idle)])
        store.applyRegistry([1: entry(session.id, .busy)])

        XCTAssertTrue(store.unreadIdle.contains(session.id), "setup: must be marked unread")
        XCTAssertEqual(store.status(for: session.id)?.activity, .busy, "setup: must be busy")

        // Begin quitting. No process is registered for this session, so this returns
        // immediately after setting the terminating flag — no real reap runs.
        await store.reapAllForQuit()

        // The race: a tick lands after the reap has cleared the registry Flight Deck reads.
        store.applyRegistry([:])

        XCTAssertTrue(
            store.unreadIdle.contains(session.id),
            "a quit-time empty tick must not prune the unread mark"
        )
        let persisted = persistence.stored?.sessions.first { $0.id == session.id }
        XCTAssertEqual(
            persisted?.activity, SessionActivity.busy.rawValue,
            "a quit-time empty tick must not overwrite the recorded activity"
        )
        XCTAssertEqual(persisted?.unread, true)
    }

    /// A tab that went away with a dev server running was working, and must still be resumed
    /// now that `shell` decodes as `idle`.
    func testIdleWithBackgroundWorkIsResumable() {
        XCTAssertTrue(SessionStore.isResumable(activity: .idle, hasBackgroundWork: true))
        XCTAssertTrue(SessionStore.isResumable(activity: .busy, hasBackgroundWork: false))
        XCTAssertFalse(SessionStore.isResumable(activity: .idle, hasBackgroundWork: false))
        // Unchanged: what a waiting tab was blocked on does not survive the restart.
        XCTAssertFalse(SessionStore.isResumable(activity: .waiting, hasBackgroundWork: true))
    }

    /// Every `sessions.json` written before this change stores `"shell"`. Reading one back must
    /// not lose the status. `SessionActivity` no longer has a `.shell` case, so
    /// `SessionActivity(rawValue: "shell")` would fail — the migration is what keeps this
    /// correct: `restoredActivity` intercepts the raw string before the enum ever sees it.
    func testLegacyShellInSnapshotRestoresAsIdleWithBackgroundWork() {
        let restored = SessionStore.restoredActivity(fromPersisted: "shell")
        XCTAssertEqual(restored.activity, .idle)
        XCTAssertTrue(restored.hasBackgroundWork)

        let plain = SessionStore.restoredActivity(fromPersisted: "idle")
        XCTAssertEqual(plain.activity, .idle)
        XCTAssertFalse(plain.hasBackgroundWork)

        XCTAssertNil(SessionStore.restoredActivity(fromPersisted: nil).activity)
    }

    /// A snapshot entry carrying `hasBackgroundWork` explicitly, bypassing the
    /// `activities:` helper above so a test can set the new field independently of the
    /// legacy `activity` string.
    private func entry(
        activity: String?, hasBackgroundWork: Bool? = nil
    ) -> (SessionSnapshot.Entry, UUID) {
        let id = UUID()
        return (
            .init(
                id: id, title: "s", workingDirectory: "/w", activity: activity,
                hasBackgroundWork: hasBackgroundWork
            ),
            id
        )
    }

    /// `restore()` must reach the same conclusion the resume prompt does: a tab that comes
    /// back from a legacy `"shell"` string belongs in `backgroundWorkSessions`, so the sidebar
    /// badge survives the relaunch rather than waiting for the next registry tick.
    func testRestoreSeedsBackgroundWorkFromLegacyShell() {
        let (record, id) = entry(activity: "shell")
        let snap = SessionSnapshot(sessions: [record], selectedSessionID: nil, sessionCounter: 1)
        let store = makeStore(snap, autoResume: true)

        store.restore(directoryExists: allDirsExist)

        XCTAssertTrue(store.backgroundWorkSessions.contains(id))
    }

    /// Same, but via the new explicit field rather than the legacy string — the shape every
    /// snapshot written after this change actually takes.
    func testRestoreSeedsBackgroundWorkFromExplicitField() {
        let (record, id) = entry(activity: "busy", hasBackgroundWork: true)
        let snap = SessionSnapshot(sessions: [record], selectedSessionID: nil, sessionCounter: 1)
        let store = makeStore(snap, autoResume: true)

        store.restore(directoryExists: allDirsExist)

        XCTAssertTrue(store.backgroundWorkSessions.contains(id))
    }

    /// The preference itself: `"idle"` alone implies `hasBackgroundWork: false`, but an
    /// explicit `true` on the same entry must win — proving the restore gate reads
    /// `entry.hasBackgroundWork ?? restored.hasBackgroundWork` rather than only the string.
    func testExplicitBackgroundWorkFieldWinsOverWhatTheStringImplies() {
        let (record, id) = entry(activity: "idle", hasBackgroundWork: true)
        let snap = SessionSnapshot(sessions: [record], selectedSessionID: nil, sessionCounter: 1)
        let store = makeStore(snap, autoResume: true)

        store.restore(directoryExists: allDirsExist)

        XCTAssertTrue(
            store.backgroundWorkSessions.contains(id),
            "an explicit hasBackgroundWork: true must not be overridden by \"idle\" implying false"
        )
    }
}
