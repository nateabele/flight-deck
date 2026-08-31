// Tests/FlightDeckTests/SessionStoreTests.swift
import XCTest
@testable import FlightDeck

@MainActor
final class SessionStoreTests: XCTestCase {
    /// Stub provider: records calls, returns no real surface (nil retained).
    final class StubProvider: SurfaceProvider {
        var madeCount = 0
        var tickCount = 0
        func makeSurface(_ config: Ghostty.SurfaceConfiguration) -> Ghostty.SurfaceView? {
            madeCount += 1
            return nil
        }
        func tick() { tickCount += 1 }
    }

    /// In-memory stand-in for the snapshot store.
    final class FakePersistence: SessionPersisting {
        var stored: SessionSnapshot?
        var saveCount = 0
        func load() -> SessionSnapshot? { stored }
        func save(_ snapshot: SessionSnapshot) { stored = snapshot; saveCount += 1 }
    }

    func testNewSessionCreatesRepoAndSelects() {
        let store = SessionStore(provider: StubProvider())
        store.display = DrawableDisplay()
        let session = store.newSession(in: URL(fileURLWithPath: "/work/foo", isDirectory: true))
        XCTAssertEqual(store.repos.count, 1)
        XCTAssertEqual(store.repos[0].displayName, "foo")
        XCTAssertEqual(store.repos[0].sessions.count, 1)
        XCTAssertEqual(store.selectedSessionID, session.id)
    }

    func testDedupesReposByStandardizedPath() {
        let store = SessionStore(provider: StubProvider())
        store.display = DrawableDisplay()
        store.newSession(in: URL(fileURLWithPath: "/work/foo", isDirectory: true))
        store.newSession(in: URL(fileURLWithPath: "/work/foo/", isDirectory: true))
        XCTAssertEqual(store.repos.count, 1)
        XCTAssertEqual(store.repos[0].sessions.count, 2)
    }

    func testTitlesIncrement() {
        let store = SessionStore(provider: StubProvider())
        store.display = DrawableDisplay()
        let a = store.newSession(in: URL(fileURLWithPath: "/work/foo", isDirectory: true))
        let b = store.newSession(in: URL(fileURLWithPath: "/work/bar", isDirectory: true))
        XCTAssertEqual(a.title, "session 1")
        XCTAssertEqual(b.title, "session 2")
    }

    func testCloseRemovesSessionButLeavesTheEmptyRepo() {
        let store = SessionStore(provider: StubProvider())
        store.display = DrawableDisplay()
        let s = store.newSession(in: URL(fileURLWithPath: "/work/foo", isDirectory: true))
        store.closeSession(s.id)
        // A project's lifetime is explicit: closing its last session empties it but does
        // not remove it. Only `closeProject` does that.
        XCTAssertEqual(store.repos.count, 1)
        XCTAssertTrue(store.repos[0].sessions.isEmpty)
        XCTAssertNil(store.selectedSessionID)
    }

    func testCloseReselectsRemainingSession() {
        let store = SessionStore(provider: StubProvider())
        store.display = DrawableDisplay()
        let s1 = store.newSession(in: URL(fileURLWithPath: "/work/foo", isDirectory: true))
        let s2 = store.newSession(in: URL(fileURLWithPath: "/work/foo", isDirectory: true))
        store.selectSession(s1.id)
        store.closeSession(s1.id)
        XCTAssertEqual(store.repos.count, 1)
        XCTAssertEqual(store.repos[0].sessions.count, 1)
        XCTAssertEqual(store.selectedSessionID, s2.id)
    }

    /// `moveSession` leaves an emptied source project standing, so an empty section can sit
    /// at index 0 with every live tab below it. Reselecting through `repos.first` comes back
    /// nil in that shape and drops the whole app to `RootView`'s "No Session" empty state
    /// while sessions are still open.
    func testCloseReselectsPastAnEmptyLeadingProject() {
        let store = SessionStore(provider: StubProvider())
        store.display = DrawableDisplay()
        let s1 = store.newSession(in: URL(fileURLWithPath: "/work/foo", isDirectory: true))
        let s2 = store.newSession(in: URL(fileURLWithPath: "/work/foo", isDirectory: true))
        let bar = URL(fileURLWithPath: "/work/bar", isDirectory: true)
        store.moveSession(s1.id, toProjectAt: bar)
        store.moveSession(s2.id, toProjectAt: bar)
        store.selectSession(s1.id)

        store.closeSession(s1.id)

        // The hazardous shape, asserted so this cannot pass vacuously.
        XCTAssertEqual(store.repos.first?.url.path, "/work/foo")
        XCTAssertTrue(store.repos.first?.sessions.isEmpty == true)

        XCTAssertEqual(store.selectedSessionID, s2.id)
        // Not just non-nil: it has to name a session that is actually still open.
        XCTAssertEqual(
            store.repos.flatMap(\.sessions).map(\.id).contains { $0 == store.selectedSessionID },
            true
        )
    }

    func testSeedInitialSessionCreatesOneHomeRepoOnce() {
        let store = SessionStore(provider: StubProvider())
        store.display = DrawableDisplay()
        let home = URL(fileURLWithPath: "/Users/tester", isDirectory: true)
        store.seedInitialSession(homeURL: home)
        store.seedInitialSession(homeURL: home) // second call must be a no-op
        XCTAssertEqual(store.repos.count, 1)
        XCTAssertEqual(store.repos[0].displayName, "tester")
        XCTAssertEqual(store.repos[0].sessions.count, 1)
        XCTAssertNotNil(store.selectedSessionID)
    }

    func testProviderInvokedPerSession() {
        let stub = StubProvider()
        let store = SessionStore(provider: stub)
        store.display = DrawableDisplay()
        store.newSession(in: URL(fileURLWithPath: "/work/foo", isDirectory: true))
        store.newSession(in: URL(fileURLWithPath: "/work/bar", isDirectory: true))
        XCTAssertEqual(stub.madeCount, 2)
        XCTAssertEqual(stub.tickCount, 2)
    }

    // MARK: Persisting status transitions

    /// Recording activity is what makes auto-resume survive a SIGKILL rather than only a
    /// clean quit, so the registry tick has to save — it is the only place activity moves.
    func testRegistryTransitionPersists() {
        let persistence = FakePersistence()
        let store = SessionStore(provider: StubProvider(), persistence: persistence)
        store.display = DrawableDisplay()
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
        store.display = DrawableDisplay()
        let s = store.newSession(in: URL(fileURLWithPath: "/work/foo", isDirectory: true))
        let rows = [pid_t(1): row(s, activity: .busy)]

        store.applyRegistry(rows)
        let settled = persistence.saveCount
        store.applyRegistry(rows)

        XCTAssertEqual(persistence.saveCount, settled)
    }

    // MARK: Unread marks outlive process state

    /// At launch `statuses` is empty until each resumed `claude` re-registers. The old
    /// blanket intersection wiped every restored mark on that first tick, before the user
    /// ever had a chance to view it.
    ///
    /// **Two sessions, deliberately.** With only the marked session present, the tick would
    /// early-return on `next != statuses` (empty to empty), `applyReadState` would never run,
    /// and the mark would survive under the buggy code too — a test that passes either way.
    /// `booted` is here to make the tick real; `waiting` is the one under test.
    func testAMarkSurvivesATickInWhichTheSessionHasNoStatusYet() {
        let store = SessionStore(provider: StubProvider())
        store.display = DrawableDisplay()
        let waiting = store.newSession(in: URL(fileURLWithPath: "/work/foo", isDirectory: true))
        let booted = store.newSession(in: URL(fileURLWithPath: "/work/bar", isDirectory: true))
        store.markUnreadForTesting([waiting.id])

        // Only `booted` has registered. `waiting`'s `claude` is still starting up.
        store.applyRegistry([1: row(booted, activity: .busy)])

        XCTAssertTrue(store.unreadIdle.contains(waiting.id))
    }

    /// A session that HAD a status and lost it — its `claude` exited while Flight Deck kept
    /// running — no longer drops the session's mark. An unread mark reflects the user's read
    /// state, not process state, so it survives the process disappearing; only the status
    /// glyph does not (`SessionStatusIcon`'s `if let status` branch draws nothing once the
    /// status is gone, and its `else if unread` branch draws the bare accent dot instead, so
    /// a statusless-but-unread session is still visibly marked).
    func testAMarkSurvivesItsStatusDisappearing() {
        let store = SessionStore(provider: StubProvider())
        store.display = DrawableDisplay()
        let s = store.newSession(in: URL(fileURLWithPath: "/work/foo", isDirectory: true))
        store.selectedSessionID = nil
        store.appIsActive = { false }

        store.applyRegistry([1: row(s, activity: .busy)])
        store.applyRegistry([1: row(s, activity: .idle)])
        XCTAssertTrue(store.unreadIdle.contains(s.id), "precondition: busy -> idle marks")

        store.applyRegistry([:])

        XCTAssertTrue(store.unreadIdle.contains(s.id))
    }

    func testClosingASessionDropsItsMark() {
        let store = SessionStore(provider: StubProvider())
        store.display = DrawableDisplay()
        let s = store.newSession(in: URL(fileURLWithPath: "/work/foo", isDirectory: true))
        store.markUnreadForTesting([s.id])

        store.closeSession(s.id)

        XCTAssertFalse(store.unreadIdle.contains(s.id))
    }

    // MARK: Mark as Unread

    /// The context menu's entry point, not the `markUnreadForTesting` seam: pins that the
    /// production `markUnread(_:)` itself lands in `unreadIdle`.
    func testMarkUnreadInsertsIntoUnreadIdle() {
        let store = SessionStore(provider: StubProvider())
        store.display = DrawableDisplay()
        let s = store.newSession(in: URL(fileURLWithPath: "/work/foo", isDirectory: true))
        XCTAssertFalse(store.unreadIdle.contains(s.id), "precondition: not yet marked")

        store.markUnread(s.id)

        XCTAssertTrue(store.unreadIdle.contains(s.id))
    }

    /// The condition the whole "Mark as Unread" feature was approved on: reactivating an
    /// inactive tab clears its mark. This is `selectedSessionID`'s `didSet`
    /// (`SessionStore.swift:47`), pinned here as well as in the UI smoke test — a unit test
    /// is what tells you *why* it broke if it ever does again.
    func testSelectingASessionClearsItsMark() {
        let store = SessionStore(provider: StubProvider())
        store.display = DrawableDisplay()
        let a = store.newSession(in: URL(fileURLWithPath: "/work/foo", isDirectory: true))
        // Created after `a`, so `b` — not `a` — holds the selection below, the way looking
        // at a different tab before coming back to the marked one would.
        _ = store.newSession(in: URL(fileURLWithPath: "/work/bar", isDirectory: true))
        store.markUnread(a.id)
        XCTAssertTrue(store.unreadIdle.contains(a.id), "precondition: marked while unselected")

        store.selectSession(a.id)

        XCTAssertFalse(store.unreadIdle.contains(a.id))
    }

    /// A registry row for `session`, in the shape `applyRegistry` resolves against.
    ///
    /// `cwd` must equal the session's own working directory: `applyRegistry` reads a
    /// differing cwd as `claude` having changed directory and retargets the tab's transcript
    /// watcher onto it, which is not what these tests are exercising and would put them on
    /// the filesystem.
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
}
