import XCTest
@testable import FlightDeck

@MainActor
final class ProjectLifetimeTests: XCTestCase {
    private func makeStore() -> (SessionStore, SessionPersistenceTests.FakePersistence) {
        let persistence = SessionPersistenceTests.FakePersistence()
        return (SessionStore(provider: nil, persistence: persistence), persistence)
    }

    func testClosingTheLastSessionLeavesTheProjectStanding() {
        let (store, persistence) = makeStore()
        let session = store.newSession(in: URL(fileURLWithPath: "/w/a", isDirectory: true))

        store.closeSession(session.id)

        XCTAssertEqual(store.repos.map(\.url.lastPathComponent), ["a"])
        XCTAssertTrue(store.repos[0].sessions.isEmpty)
        XCTAssertEqual(persistence.stored?.projects?.map(\.path), ["/w/a"])
        XCTAssertEqual(persistence.stored?.sessions.count, 0)
    }

    func testAnEmptyProjectSurvivesARelaunch() {
        let (store, persistence) = makeStore()
        let session = store.newSession(in: URL(fileURLWithPath: "/w/a", isDirectory: true))
        store.closeSession(session.id)

        let relaunched = SessionStore(provider: nil, persistence: persistence)

        XCTAssertTrue(relaunched.restore(directoryExists: { _ in true }))
        XCTAssertEqual(relaunched.repos.map(\.url.lastPathComponent), ["a"])
    }

    func testCloseProjectRemovesTheProjectAndAllItsSessions() {
        let (store, _) = makeStore()
        store.newSession(in: URL(fileURLWithPath: "/w/a", isDirectory: true))
        store.newSession(in: URL(fileURLWithPath: "/w/a", isDirectory: true))
        store.newSession(in: URL(fileURLWithPath: "/w/b", isDirectory: true))
        let project = store.repos[0].id

        store.closeProject(project)

        XCTAssertEqual(store.repos.map(\.url.lastPathComponent), ["b"])
    }

    func testCloseProjectTearsDownEveryChildsStatus() {
        let (store, _) = makeStore()
        let a = store.newSession(in: URL(fileURLWithPath: "/w/a", isDirectory: true))
        let b = store.newSession(in: URL(fileURLWithPath: "/w/a", isDirectory: true))
        let project = store.repos[0].id
        store.applyRegistryForTesting([a.id: .init(activity: .busy), b.id: .init(activity: .waiting)])

        store.closeProject(project)

        XCTAssertNil(store.status(for: a.id))
        XCTAssertNil(store.status(for: b.id))
    }

    /// The spec asks for "watchers stopped … notifications withdrawn" on `closeProject`, not
    /// just `status(for:)` going nil. `watchedSessionIDs` and a `Notifying` spy are the seams
    /// that let this be asserted directly rather than inferred from the status map alone.
    func testCloseProjectStopsEveryChildsWatcherAndWithdrawsItsNotifications() {
        let (store, _) = makeStore()
        let spy = SpyNotifier()
        store.notifier = spy
        let a = store.newSession(in: URL(fileURLWithPath: "/w/a", isDirectory: true))
        let b = store.newSession(in: URL(fileURLWithPath: "/w/a", isDirectory: true))
        let project = store.repos[0].id
        XCTAssertTrue(store.watchedSessionIDs.isSuperset(of: [a.id, b.id]))

        store.closeProject(project)

        XCTAssertTrue(store.watchedSessionIDs.isDisjoint(with: [a.id, b.id]))
        XCTAssertEqual(Set(spy.withdrawn), [a.id, b.id])
    }

    private final class SpyNotifier: Notifying {
        var withdrawn: [UUID] = []
        func requestAuthorization() {}
        func notify(sessionID: UUID, title: String, subtitle: String, body: String) {}
        func withdraw(sessionID: UUID) { withdrawn.append(sessionID) }
    }

    func testCloseProjectMovesTheSelectionOffItsChildren() {
        let (store, _) = makeStore()
        store.newSession(in: URL(fileURLWithPath: "/w/b", isDirectory: true))
        let doomed = store.newSession(in: URL(fileURLWithPath: "/w/a", isDirectory: true))
        let project = store.repos.first { $0.url.lastPathComponent == "a" }!.id
        store.selectedSessionID = doomed.id

        store.closeProject(project)

        XCTAssertNotEqual(store.selectedSessionID, doomed.id)
        XCTAssertNotNil(store.selectedSessionID)
    }

    func testCloseProjectOnAnEmptyProjectJustRemovesIt() {
        let (store, _) = makeStore()
        let session = store.newSession(in: URL(fileURLWithPath: "/w/a", isDirectory: true))
        let project = store.repos[0].id
        store.closeSession(session.id)

        store.closeProject(project)

        XCTAssertTrue(store.repos.isEmpty)
    }

    func testCloseProjectWithAnUnknownIDDoesNothing() {
        let (store, _) = makeStore()
        store.newSession(in: URL(fileURLWithPath: "/w/a", isDirectory: true))

        store.closeProject(UUID())

        XCTAssertEqual(store.repos.count, 1)
    }
}
