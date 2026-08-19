import XCTest
import FleetKit
@testable import FlightDeck

/// These tests assert the *events*, and the harness's drift check independently asserts that
/// the events add up to the store. Both matter: the events are the contract a client sees,
/// and the drift check is what notices a site nobody thought to test.
@MainActor
final class FleetStructureEmissionTests: XCTestCase {
    private func store() -> SessionStore { SessionStore(provider: nil, persistence: nil) }

    private func recorded(_ replicator: FleetReplicator) -> [FleetEvent] { replicator.recorded }

    func testCreatingTheFirstSessionAnnouncesItsProjectThenItself() {
        let store = store()
        let replicator = attachedReplicator(to: store)
        let session = store.newSession(in: URL(fileURLWithPath: "/w/alpha"))

        guard case .projectAdded(let project, let at) = recorded(replicator).first else {
            return XCTFail("a new project must be announced before the session inside it")
        }
        XCTAssertEqual(at, 0)
        XCTAssertEqual(project.name, "alpha")
        XCTAssertTrue(project.sessions.isEmpty,
                      "the project arrives empty; its session is a separate event")
        XCTAssertTrue(recorded(replicator).contains(where: {
            if case .sessionAdded(let s, project.id, _) = $0 { return s.id == session.id }
            return false
        }))
    }

    func testASecondSessionInTheSameProjectAnnouncesNoSecondProject() {
        let store = store()
        _ = store.newSession(in: URL(fileURLWithPath: "/w/alpha"))
        let replicator = attachedReplicator(to: store)
        _ = store.newSession(in: URL(fileURLWithPath: "/w/alpha"))
        XCTAssertFalse(recorded(replicator).contains { if case .projectAdded = $0 { return true }; return false })
    }

    /// A session landing in a collapsed project springs it open, and a client that missed
    /// that would render the new session inside a project that still looks closed.
    func testASessionLandingInACollapsedProjectAnnouncesTheExpansion() {
        let store = store()
        _ = store.newSession(in: URL(fileURLWithPath: "/w/alpha"))
        let project = store.repos[0].id
        store.setCollapsed(true, forProjectAt: project)
        let replicator = attachedReplicator(to: store)
        _ = store.newSession(in: URL(fileURLWithPath: "/w/alpha"))
        XCTAssertTrue(recorded(replicator).contains(.projectCollapsed(id: project, isCollapsed: false)))
    }

    func testClosingASessionAnnouncesItsRemoval() {
        let store = store()
        let session = store.newSession(in: URL(fileURLWithPath: "/w/alpha"))
        let replicator = attachedReplicator(to: store)
        store.closeSession(session.id)
        XCTAssertTrue(recorded(replicator).contains(.sessionRemoved(id: session.id)))
    }

    /// Closing a project closes its sessions first, so a client sees each leave before the
    /// project does. Order matters here: a `projectRemoved` alone would be enough for the
    /// snapshot, but the timeline and notifications read individual removals.
    func testClosingAProjectAnnouncesItsSessionsThenItself() {
        let store = store()
        let session = store.newSession(in: URL(fileURLWithPath: "/w/alpha"))
        let project = store.repos[0].id
        let replicator = attachedReplicator(to: store)
        store.closeProject(project)
        let events = recorded(replicator)
        let sessionAt = events.firstIndex(of: .sessionRemoved(id: session.id))
        let projectAt = events.firstIndex(of: .projectRemoved(id: project))
        XCTAssertNotNil(sessionAt)
        XCTAssertNotNil(projectAt)
        XCTAssertLessThan(try XCTUnwrap(sessionAt), try XCTUnwrap(projectAt))
    }

    func testCollapsingAProjectIsAnnouncedOnceAndOnlyOnAChange() {
        let store = store()
        _ = store.newSession(in: URL(fileURLWithPath: "/w/alpha"))
        let project = store.repos[0].id
        let replicator = attachedReplicator(to: store)
        store.setCollapsed(true, forProjectAt: project)
        store.setCollapsed(true, forProjectAt: project)
        XCTAssertEqual(
            recorded(replicator).filter { if case .projectCollapsed = $0 { return true }; return false }.count,
            1
        )
    }

    func testMovingASessionToAnotherProjectAnnouncesTheMoveNotAnAddAndRemove() {
        let store = store()
        let session = store.newSession(in: URL(fileURLWithPath: "/w/alpha"))
        _ = store.newSession(in: URL(fileURLWithPath: "/w/beta"))
        let beta = store.repos[1].id
        let replicator = attachedReplicator(to: store)
        store.moveSession(session.id, toProjectAt: URL(fileURLWithPath: "/w/beta"))
        XCTAssertTrue(recorded(replicator).contains(where: {
            if case .sessionMoved(session.id, beta, _) = $0 { return true }
            return false
        }))
        XCTAssertFalse(recorded(replicator).contains(.sessionRemoved(id: session.id)),
                       "a move must not read as a close on the client")
    }

    func testMovingASessionIntoAProjectThatDoesNotExistYetAnnouncesItFirst() {
        let store = store()
        let session = store.newSession(in: URL(fileURLWithPath: "/w/alpha"))
        let replicator = attachedReplicator(to: store)
        store.moveSession(session.id, toProjectAt: URL(fileURLWithPath: "/w/gamma"))
        guard let firstProject = recorded(replicator).first(where: {
            if case .projectAdded = $0 { return true }; return false
        }), case .projectAdded(let project, _) = firstProject else {
            return XCTFail("the destination project must be announced before the move")
        }
        XCTAssertEqual(project.name, "gamma")
        XCTAssertTrue(recorded(replicator).contains(where: {
            if case .sessionMoved(session.id, project.id, _) = $0 { return true }
            return false
        }))
    }

    func testReorderingTheSidebarAnnouncesTheNewOrder() {
        let store = store()
        _ = store.newSession(in: URL(fileURLWithPath: "/w/alpha"))
        _ = store.newSession(in: URL(fileURLWithPath: "/w/beta"))
        let order = store.repos.map(\.id)
        let replicator = attachedReplicator(to: store)
        store.moveSidebarRows(fromOffsets: IndexSet(integer: 2), toOffset: 0)
        XCTAssertTrue(recorded(replicator).contains(.projectsReordered(order: [order[1], order[0]])))
    }
}
