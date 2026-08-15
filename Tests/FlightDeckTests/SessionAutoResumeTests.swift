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
        XCTAssertEqual(store.pendingResumePrompts[ids[0]], expected)
        XCTAssertEqual(store.pendingResumePrompts[ids[1]], expected)
    }
}
