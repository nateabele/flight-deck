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
    private let bar = URL(fileURLWithPath: "/work/bar", isDirectory: true)

    private func makeStore(_ persistence: FakePersistence? = nil) -> (SessionStore, [UUID]) {
        let store = SessionStore(provider: StubProvider(), persistence: persistence)
        let ids = (0..<3).map { _ in store.newSession(in: foo).id }
        return (store, ids)
    }

    private func projectID(_ url: URL, in store: SessionStore) -> UUID {
        store.repos.first { $0.url.standardizedFileURL == url.standardizedFileURL }!.id
    }

    /// Two sessions in `foo` and a second project's (`bar`) own session, none of them selected
    /// at construction (`selecting: false`) — unlike `makeStore()` above, which auto-selects
    /// the last one created. These tests assert the exact shape of `back`, and that auto-select
    /// would record a spurious entry before the test's own first assignment ever runs.
    private func makeProjectHistoryStore(_ persistence: FakePersistence? = nil) -> (SessionStore, [UUID]) {
        let store = SessionStore(provider: StubProvider(), persistence: persistence)
        let ids = (0..<2).map { _ in store.newSession(in: foo, selecting: false).id }
        store.newSession(in: bar, selecting: false)
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
        XCTAssertEqual(store.selectionHistory.forward, [.session(ids[1])])
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
        XCTAssertEqual(store.selectionHistory.back, [.session(ids[0]), .session(ids[1])])
        XCTAssertEqual(store.selectionHistory.forward, [.session(ids[0])])
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

    func testSessionToProjectToSessionRecordsTwoEntries() {
        let (store, ids) = makeProjectHistoryStore()
        store.selectedSessionID = ids[0]
        store.selectProject(projectID(foo, in: store))
        store.selectedSessionID = ids[1]
        XCTAssertEqual(store.selectionHistory.back,
                       [.session(ids[0]), .project(path: foo.standardizedFileURL.path)])
    }

    func testBackReopensAProjectView() {
        let (store, ids) = makeProjectHistoryStore()
        store.selectedSessionID = ids[0]
        store.selectProject(projectID(foo, in: store))
        store.selectedSessionID = ids[1]
        store.goBack()
        XCTAssertEqual(store.selectedProjectID, projectID(foo, in: store))
        store.goBack()
        XCTAssertNil(store.selectedProjectID)
        XCTAssertEqual(store.selectedSessionID, ids[0])
    }

    func testForwardFromAProjectViewReturnsToTheSession() {
        let (store, ids) = makeProjectHistoryStore()
        store.selectedSessionID = ids[0]
        store.selectProject(projectID(foo, in: store))
        store.goBack()
        XCTAssertNil(store.selectedProjectID)
        store.goForward()
        XCTAssertEqual(store.selectedProjectID, projectID(foo, in: store))
    }

    func testAProjectEntrySurvivesARelaunchByPath() {
        let persistence = FakePersistence()
        let (store, ids) = makeProjectHistoryStore(persistence)
        store.selectProject(projectID(foo, in: store))
        store.selectedSessionID = ids[1]
        let relaunched = SessionStore(provider: StubProvider(), persistence: persistence)
        _ = relaunched.restore(directoryExists: { _ in true })
        relaunched.goBack()
        XCTAssertEqual(relaunched.selectedProjectID, projectID(foo, in: relaunched))
    }
}
