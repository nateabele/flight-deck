import XCTest
@testable import FlightDeck

@MainActor
final class SelectionHistoryStoreTests: XCTestCase {
    private final class StubProvider: SurfaceProvider {
        func makeSurface(_ config: Ghostty.SurfaceConfiguration) -> Ghostty.SurfaceView? { nil }
        func tick() {}
        var defaultFontSize: Float { 12 }
    }
    private final class FakePersistence: SessionPersisting {
        var stored: SessionSnapshot?
        func load() -> SessionSnapshot? { stored }
        func save(_ snapshot: SessionSnapshot) { stored = snapshot }
    }

    private let foo = URL(fileURLWithPath: "/work/foo", isDirectory: true)

    private func makeStore(_ persistence: FakePersistence? = nil) -> (SessionStore, [UUID]) {
        let store = SessionStore(provider: StubProvider(), persistence: persistence)
        let ids = (0..<3).map { _ in store.newSession(in: foo).id }
        return (store, ids)
    }

    func testASidebarSelectionIsRecordedAndBackReturns() {
        let (store, ids) = makeStore()
        store.selectedSessionID = ids[0]
        store.selectedSessionID = ids[2]   // what `List(selection:)` does on a click
        store.goBack()
        XCTAssertEqual(store.selectedSessionID, ids[0])
        store.goForward()
        XCTAssertEqual(store.selectedSessionID, ids[2])
    }

    func testReselectingTheSameSessionRecordsNothing() {
        let (store, ids) = makeStore()
        store.selectedSessionID = ids[1]
        let before = store.selectionHistory
        store.selectedSessionID = ids[1]
        XCTAssertEqual(store.selectionHistory, before)
    }

    func testTraversalDoesNotRecordItself() {
        let (store, ids) = makeStore()
        store.selectedSessionID = ids[0]
        store.selectedSessionID = ids[1]
        let before = store.selectionHistory.back
        store.goBack()
        XCTAssertEqual(store.selectionHistory.back, Array(before.dropLast()))
        XCTAssertEqual(store.selectionHistory.forward, [.session(id: ids[1])])
    }

    func testBackSkipsAClosedSession() {
        let (store, ids) = makeStore()
        store.selectedSessionID = ids[0]
        store.selectedSessionID = ids[1]
        store.selectedSessionID = ids[2]
        store.closeSession(ids[1])
        store.selectedSessionID = ids[2]
        store.goBack()
        XCTAssertEqual(store.selectedSessionID, ids[0])
    }

    func testBackWithNothingLiveLeavesSelectionAlone() {
        let (store, ids) = makeStore()
        store.selectedSessionID = ids[0]
        store.selectedSessionID = ids[1]
        store.closeSession(ids[0])
        store.closeSession(ids[2])
        // The only live entry left is the current row itself, which Back must never land on.
        store.goBack()
        XCTAssertEqual(store.selectedSessionID, ids[1])
    }

    /// `closeSession`'s selected-session fallback (`selectionAfterClosing`) can reassign
    /// `selectedSessionID` once per child as `closeProject` works through the tabs it owns —
    /// unsuppressed, each of those reassignments would push its own Back entry, turning one
    /// project close into a stack of hops that all point inside a project which no longer
    /// exists.
    func testClosingAProjectRecordsOneHistoryEntry() {
        let (store, ids) = makeStore()
        let bar = URL(fileURLWithPath: "/work/bar", isDirectory: true)
        _ = store.newSession(in: bar)   // somewhere for the selection to land after the close
        store.selectedSessionID = ids[0]
        let backBefore = store.selectionHistory.back
        let project = store.repos.first { $0.sessions.contains { $0.id == ids[0] } }!.id

        store.closeProject(project)

        XCTAssertEqual(store.selectionHistory.back, backBefore + [.session(id: ids[0])])
    }

    /// `List(selection:)` can write nil on a deselect between two real clicks. `oldValue` alone
    /// would be nil by the time Y lands, dropping the X->Y transition entirely and making Back
    /// from Y skip straight past X.
    func testADeselectBetweenTwoClicksStillRecordsTheTransition() {
        let (store, ids) = makeStore()
        store.selectedSessionID = ids[0]
        store.selectedSessionID = nil
        store.selectedSessionID = ids[1]
        store.goBack()
        XCTAssertEqual(store.selectedSessionID, ids[0])
    }

    func testANewSelectedSessionIsRecorded() {
        let (store, ids) = makeStore()
        store.selectedSessionID = ids[0]
        let created = store.newSession(in: foo)   // selects it, same as `selecting: true`
        XCTAssertEqual(store.selectedSessionID, created.id)
        store.goBack()
        XCTAssertEqual(store.selectedSessionID, ids[0])
    }

    func testBackSkipsTheCurrentSession() {
        let (store, ids) = makeStore()
        store.selectedSessionID = ids[0]
        store.selectedSessionID = ids[1]
        store.selectedSessionID = ids[0]   // the stack's top entry is now the current session
        store.closeSession(ids[1])
        store.goBack()
        // Must skip past the dead `ids[1]` entry and the live-but-current `ids[0]` entry to
        // land on `ids[2]`, never staying on `ids[0]` while still consuming history.
        XCTAssertEqual(store.selectedSessionID, ids[2])
        XCTAssertEqual(store.selectionHistory.back, [.session(id: ids[0]), .session(id: ids[1])])
        XCTAssertEqual(store.selectionHistory.forward, [.session(id: ids[0])])
    }

    func testReopenedSessionIsReachableAgain() {
        let (store, ids) = makeStore()
        store.selectedSessionID = ids[0]
        store.selectedSessionID = ids[1]
        store.closeSession(ids[0])
        store.reopenLastClosed()
        store.selectedSessionID = ids[1]
        store.goBack()
        XCTAssertEqual(store.selectedSessionID, ids[0])
    }

    func testHistorySurvivesARelaunch() {
        let persistence = FakePersistence()
        let (store, ids) = makeStore(persistence)
        store.selectedSessionID = ids[0]
        store.selectedSessionID = ids[2]
        XCTAssertNotNil(persistence.stored?.selectionHistory)

        let relaunched = SessionStore(provider: StubProvider(), persistence: persistence)
        _ = relaunched.restore(directoryExists: { _ in true })
        XCTAssertEqual(relaunched.selectedSessionID, ids[2])
        relaunched.goBack()
        XCTAssertEqual(relaunched.selectedSessionID, ids[0])
    }

    /// `restore` assigns `selectedSessionID`, whose `didSet` persists. Unless the history is
    /// loaded before that assignment, launch overwrites the saved history with an empty one.
    func testRestoreKeepsThePersistedHistory() {
        let persistence = FakePersistence()
        let (store, ids) = makeStore(persistence)
        store.selectedSessionID = ids[0]
        store.selectedSessionID = ids[1]
        let saved = persistence.stored?.selectionHistory

        let relaunched = SessionStore(provider: StubProvider(), persistence: persistence)
        _ = relaunched.restore(directoryExists: { _ in true })
        XCTAssertEqual(persistence.stored?.selectionHistory, saved)
        XCTAssertEqual(relaunched.selectionHistory, saved)
    }

    func testSnapshotWithoutHistoryStillRestores() throws {
        let id = UUID()
        let json = """
        {"sessions":[{"id":"\(id.uuidString)","title":"a","workingDirectory":"/w"}],
         "selectedSessionID":"\(id.uuidString)","sessionCounter":1}
        """
        let snapshot = try JSONDecoder().decode(SessionSnapshot.self, from: Data(json.utf8))
        XCTAssertNil(snapshot.selectionHistory)
        let persistence = FakePersistence()
        persistence.stored = snapshot
        let store = SessionStore(provider: StubProvider(), persistence: persistence)
        _ = store.restore(directoryExists: { _ in true })
        XCTAssertEqual(store.selectedSessionID, id)
        XCTAssertTrue(store.selectionHistory.isEmpty)
    }

    func testEmptyHistoryIsWrittenAsNil() {
        let persistence = FakePersistence()
        let store = SessionStore(provider: StubProvider(), persistence: persistence)
        store.newSession(in: foo)
        XCTAssertNil(persistence.stored?.selectionHistory)
    }

    /// A malformed `selectionHistory` (an unknown case, a wrong-shaped stack) must not throw
    /// the whole `SessionSnapshot` decode — that is how `load()` used to return nil, starting
    /// the app with every tab gone and letting the next save overwrite `sessions.json` with
    /// that emptiness. `{"folder":{}}` stands in for an entry this build has never heard of
    /// (an old `_0`-shaped value or a future case); it is dropped, and its live sibling is not.
    func testMalformedSelectionHistoryDoesNotWipeTheSessions() throws {
        let id = UUID()
        let json = """
        {"sessions":[{"id":"\(id.uuidString)","title":"a","workingDirectory":"/w"}],
         "selectedSessionID":"\(id.uuidString)","sessionCounter":1,
         "selectionHistory":{"back":[{"folder":{}},{"session":{"id":"\(UUID().uuidString)"}}],"forward":7}}
        """
        let snapshot = try JSONDecoder().decode(SessionSnapshot.self, from: Data(json.utf8))
        let persistence = FakePersistence()
        persistence.stored = snapshot
        let store = SessionStore(provider: StubProvider(), persistence: persistence)
        _ = store.restore(directoryExists: { _ in true })
        XCTAssertEqual(store.selectedSessionID, id)
        XCTAssertEqual(store.selectionHistory.back.count, 1)
        XCTAssertTrue(store.selectionHistory.forward.isEmpty)
    }

    /// Same failure mode, but the whole field is the wrong type rather than one bad element.
    func testNonObjectSelectionHistoryDoesNotWipeTheSessions() throws {
        let id = UUID()
        let json = """
        {"sessions":[{"id":"\(id.uuidString)","title":"a","workingDirectory":"/w"}],
         "selectedSessionID":"\(id.uuidString)","sessionCounter":1,
         "selectionHistory":"garbage"}
        """
        let snapshot = try JSONDecoder().decode(SessionSnapshot.self, from: Data(json.utf8))
        let persistence = FakePersistence()
        persistence.stored = snapshot
        let store = SessionStore(provider: StubProvider(), persistence: persistence)
        _ = store.restore(directoryExists: { _ in true })
        XCTAssertEqual(store.selectedSessionID, id)
        XCTAssertTrue(store.selectionHistory.isEmpty)
    }
}
