import XCTest
@testable import FlightDeck

@MainActor
final class ProjectPersistenceTests: XCTestCase {
    private let allDirsExist: (String) -> Bool = { _ in true }

    /// v1 snapshots predate the field. Decoding must not throw, or the first launch after
    /// this change wipes every tab and every project.
    func testV1SnapshotWithoutProjectsDecodes() throws {
        let id = UUID()
        let json = """
        {"sessions":[{"id":"\(id.uuidString)","title":"a","workingDirectory":"/w"}],\
        "sessionCounter":1}
        """

        let snapshot = try JSONDecoder().decode(SessionSnapshot.self, from: Data(json.utf8))

        XCTAssertNil(snapshot.projects)
    }

    func testRestoreWithoutProjectsFallsBackToEncounterOrder() {
        let persistence = SessionPersistenceTests.FakePersistence()
        persistence.stored = SessionSnapshot(
            sessions: [
                .init(id: UUID(), title: "b", workingDirectory: "/w/b"),
                .init(id: UUID(), title: "a", workingDirectory: "/w/a"),
            ],
            sessionCounter: 2
        )
        let store = SessionStore(provider: nil, persistence: persistence)

        XCTAssertTrue(store.restore(directoryExists: allDirsExist))
        XCTAssertEqual(store.repos.map(\.url.lastPathComponent), ["b", "a"])
        XCTAssertEqual(store.repos.map(\.isCollapsed), [false, false])
    }

    func testRestoreHonoursRecordedProjectOrderAndCollapsedState() {
        let persistence = SessionPersistenceTests.FakePersistence()
        persistence.stored = SessionSnapshot(
            sessions: [
                .init(id: UUID(), title: "a", workingDirectory: "/w/a"),
                .init(id: UUID(), title: "b", workingDirectory: "/w/b"),
            ],
            projects: [
                .init(path: "/w/b", isCollapsed: true),
                .init(path: "/w/a", isCollapsed: false),
            ],
            sessionCounter: 2
        )
        let store = SessionStore(provider: nil, persistence: persistence)

        XCTAssertTrue(store.restore(directoryExists: allDirsExist))
        XCTAssertEqual(store.repos.map(\.url.lastPathComponent), ["b", "a"])
        XCTAssertEqual(store.repos.map(\.isCollapsed), [true, false])
    }

    func testRestoreAppendsAProjectTheRecordedListDidNotCover() {
        let persistence = SessionPersistenceTests.FakePersistence()
        persistence.stored = SessionSnapshot(
            sessions: [
                .init(id: UUID(), title: "a", workingDirectory: "/w/a"),
                .init(id: UUID(), title: "c", workingDirectory: "/w/c"),
            ],
            projects: [.init(path: "/w/a", isCollapsed: false)],
            sessionCounter: 2
        )
        let store = SessionStore(provider: nil, persistence: persistence)

        XCTAssertTrue(store.restore(directoryExists: allDirsExist))
        XCTAssertEqual(store.repos.map(\.url.lastPathComponent), ["a", "c"])
    }

    func testRestoreSkipsAProjectWhoseDirectoryIsGone() {
        let persistence = SessionPersistenceTests.FakePersistence()
        persistence.stored = SessionSnapshot(
            sessions: [.init(id: UUID(), title: "a", workingDirectory: "/w/a")],
            projects: [
                .init(path: "/w/deleted", isCollapsed: false),
                .init(path: "/w/a", isCollapsed: false),
            ],
            sessionCounter: 1
        )
        let store = SessionStore(provider: nil, persistence: persistence)

        XCTAssertTrue(store.restore(directoryExists: { $0 != "/w/deleted" }))
        XCTAssertEqual(store.repos.map(\.url.lastPathComponent), ["a"])
    }

    func testAProjectsOnlySnapshotRestoresTheProjectAndSeedsNoSession() {
        let persistence = SessionPersistenceTests.FakePersistence()
        persistence.stored = SessionSnapshot(
            sessions: [],
            projects: [.init(path: "/w/a", isCollapsed: true)],
            sessionCounter: 3
        )
        let store = SessionStore(provider: nil, persistence: persistence)

        // Without this, closing every session but keeping the projects would discard the
        // project list on the next launch.
        XCTAssertTrue(store.restore(directoryExists: allDirsExist))
        XCTAssertEqual(store.repos.map(\.url.lastPathComponent), ["a"])
        XCTAssertTrue(store.repos[0].sessions.isEmpty)
        XCTAssertTrue(store.repos[0].isCollapsed)
    }

    func testAnEmptySnapshotStillRestoresNothing() {
        let persistence = SessionPersistenceTests.FakePersistence()
        persistence.stored = SessionSnapshot(sessions: [], projects: [], sessionCounter: 0)
        let store = SessionStore(provider: nil, persistence: persistence)

        XCTAssertFalse(store.restore(directoryExists: allDirsExist))
    }

    func testPersistWritesProjectsInOrderWithCollapsedState() {
        let persistence = SessionPersistenceTests.FakePersistence()
        let store = SessionStore(provider: nil, persistence: persistence)
        store.newSession(in: URL(fileURLWithPath: "/w/a", isDirectory: true))
        store.newSession(in: URL(fileURLWithPath: "/w/b", isDirectory: true))
        store.setCollapsed(true, forProjectAt: store.repos[0].id)

        XCTAssertEqual(persistence.stored?.projects?.map(\.path), ["/w/a", "/w/b"])
        XCTAssertEqual(persistence.stored?.projects?.map(\.isCollapsed), [true, false])
    }

    func testMoveSidebarRowsReordersProjectsAndPersists() {
        let persistence = SessionPersistenceTests.FakePersistence()
        let store = SessionStore(provider: nil, persistence: persistence)
        store.newSession(in: URL(fileURLWithPath: "/w/a", isDirectory: true))
        store.newSession(in: URL(fileURLWithPath: "/w/b", isDirectory: true))

        // Rows are [P_a, a0, P_b, b0]; moving row 0 to 4 appends project a after b.
        store.moveSidebarRows(fromOffsets: IndexSet(integer: 0), toOffset: 4)

        XCTAssertEqual(store.repos.map(\.url.lastPathComponent), ["b", "a"])
        XCTAssertEqual(persistence.stored?.projects?.map(\.path), ["/w/b", "/w/a"])
    }

    func testMoveSidebarRowsIgnoresAnIllegalMove() {
        let persistence = SessionPersistenceTests.FakePersistence()
        let store = SessionStore(provider: nil, persistence: persistence)
        // Project a holds two sessions so a CLAMP (rather than a reject) of the illegal move
        // below would be distinguishable: clamping row 1 to the nearest legal offset would
        // still land it inside project a's own block and reorder ["first", "second"] to
        // ["second", "first"], while a true reject leaves both `repos` and each project's
        // session order untouched. With only one session in project a, a clamp and a reject
        // produce an identical `repos` order and this test could not tell them apart.
        let first = store.newSession(in: URL(fileURLWithPath: "/w/a", isDirectory: true))
        let second = store.newSession(in: URL(fileURLWithPath: "/w/a", isDirectory: true))
        store.newSession(in: URL(fileURLWithPath: "/w/b", isDirectory: true))

        // Rows are [P_a, a0, a1, P_b, b0]; row 1 is one of project a's own sessions, row 4 is
        // inside project b's block.
        store.moveSidebarRows(fromOffsets: IndexSet(integer: 1), toOffset: 4)

        XCTAssertEqual(store.repos.map(\.url.lastPathComponent), ["a", "b"])
        XCTAssertEqual(store.repos[0].sessions.map(\.id), [first.id, second.id])
    }
}
