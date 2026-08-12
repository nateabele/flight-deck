import XCTest
@testable import FlightDeck

@MainActor
final class SessionProjectMoveTests: XCTestCase {
    private func makeStore() -> SessionStore {
        let store = SessionStore(provider: nil, persistence: nil)
        store.titleResolver = { _, done in done(nil) }
        return store
    }

    private func row(_ sid: UUID, pid: pid_t = 1, cwd: String,
                     procStart: String = "start-a") -> ClaudeStatusFile.Entry {
        .init(pid: pid, sessionID: sid, activity: .busy, waitingFor: nil,
              startedAt: 1, cwd: cwd, procStart: procStart)
    }

    func testMoveRelocatesTheSessionToAnExistingProject() {
        let store = makeStore()
        let a = store.newSession(in: URL(fileURLWithPath: "/a", isDirectory: true))
        _ = store.newSession(in: URL(fileURLWithPath: "/b", isDirectory: true))

        store.moveSession(a.id, toProjectAt: URL(fileURLWithPath: "/b", isDirectory: true))

        let b = store.repos.first { $0.url.path == "/b" }
        XCTAssertEqual(b?.sessions.map(\.id).contains(a.id), true)
        XCTAssertEqual(store.repos.count, 2)
    }

    func testMoveCreatesTheDestinationProjectWhenAbsent() {
        let store = makeStore()
        let a = store.newSession(in: URL(fileURLWithPath: "/a", isDirectory: true))

        store.moveSession(a.id, toProjectAt: URL(fileURLWithPath: "/new", isDirectory: true))

        XCTAssertEqual(store.repos.count, 2)
        XCTAssertEqual(
            store.repos.first { $0.url.path == "/new" }?.sessions.map(\.id), [a.id]
        )
    }

    /// A project with no sessions is a legitimate sidebar state. Unlike `closeSession`,
    /// moving out does not prune the source.
    func testMoveLeavesAnEmptiedSourceProjectStanding() {
        let store = makeStore()
        let a = store.newSession(in: URL(fileURLWithPath: "/a", isDirectory: true))

        store.moveSession(a.id, toProjectAt: URL(fileURLWithPath: "/new", isDirectory: true))

        let source = store.repos.first { $0.url.path == "/a" }
        XCTAssertNotNil(source)
        XCTAssertTrue(source!.sessions.isEmpty)
    }

    func testMoveUpdatesTheSessionsWorkingDirectory() {
        let store = makeStore()
        let a = store.newSession(in: URL(fileURLWithPath: "/a", isDirectory: true))

        store.moveSession(a.id, toProjectAt: URL(fileURLWithPath: "/new", isDirectory: true))

        XCTAssertEqual(
            store.repos.flatMap(\.sessions).first { $0.id == a.id }?.workingDirectory, "/new"
        )
    }

    func testMoveKeepsTheSelection() {
        let store = makeStore()
        let a = store.newSession(in: URL(fileURLWithPath: "/a", isDirectory: true))

        store.moveSession(a.id, toProjectAt: URL(fileURLWithPath: "/new", isDirectory: true))

        XCTAssertEqual(store.selectedSessionID, a.id)
    }

    func testMoveToTheSameProjectIsANoOp() {
        let store = makeStore()
        let a = store.newSession(in: URL(fileURLWithPath: "/a", isDirectory: true))

        store.moveSession(a.id, toProjectAt: URL(fileURLWithPath: "/a", isDirectory: true))

        XCTAssertEqual(store.repos.count, 1)
        XCTAssertEqual(store.repos.first?.sessions.map(\.id), [a.id])
    }

    /// The registry drives it: a resume that changes cwd moves the tab.
    func testRegistryCwdChangeMovesTheTab() {
        let store = makeStore()
        let a = store.newSession(in: URL(fileURLWithPath: "/a", isDirectory: true))

        store.applyRegistry([1: row(a.pinnedConversationID, cwd: "/a")])
        store.applyRegistry([1: row(a.pinnedConversationID, cwd: "/moved")])

        XCTAssertEqual(
            store.repos.first { $0.url.path == "/moved" }?.sessions.map(\.id), [a.id]
        )
    }

    func testRegistryCanRepinAndMoveInOneTick() {
        let store = makeStore()
        let a = store.newSession(in: URL(fileURLWithPath: "/a", isDirectory: true))
        let resumed = UUID()

        store.applyRegistry([1: row(a.pinnedConversationID, cwd: "/a")])
        store.applyRegistry([1: row(resumed, cwd: "/moved")])

        XCTAssertEqual(store.pinnedConversationID(of: a.id), resumed)
        XCTAssertEqual(
            store.repos.first { $0.url.path == "/moved" }?.sessions.map(\.id), [a.id]
        )
    }
}
