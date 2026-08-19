import XCTest
import FleetKit

final class FleetEventApplicationTests: XCTestCase {
    private let projectID = UUID()
    private let sessionID = UUID()

    private func session(_ id: UUID, _ title: String) -> WireSession {
        WireSession(id: id, title: title, agent: "claude")
    }

    private func base() -> FleetSnapshot {
        FleetSnapshot(projects: [
            WireProject(id: projectID, name: "flight-deck", path: "/w/fd",
                        sessions: [session(sessionID, "one")])
        ])
    }

    // MARK: Sessions

    func testASessionIsAddedIntoItsProjectAtTheGivenIndex() {
        let newID = UUID()
        let after = base().applying([
            .sessionAdded(session(newID, "zero"), project: projectID, at: 0)
        ])
        XCTAssertEqual(after.projects[0].sessions.map(\.id), [newID, sessionID])
    }

    /// An out-of-range index appends rather than trapping. The index came off a wire from a
    /// machine whose fleet has moved on since; a client must never crash on one.
    func testAnOutOfRangeInsertionAppends() {
        let newID = UUID()
        let after = base().applying([
            .sessionAdded(session(newID, "last"), project: projectID, at: 99)
        ])
        XCTAssertEqual(after.projects[0].sessions.map(\.id), [sessionID, newID])
    }

    func testASessionIsRemoved() {
        XCTAssertTrue(base().applying([.sessionRemoved(id: sessionID)]).projects[0].sessions.isEmpty)
    }

    func testRenamingChangesTheTitle() {
        let after = base().applying([.renamed(id: sessionID, title: "two", origin: .user)])
        XCTAssertEqual(after.projects[0].sessions[0].title, "two")
    }

    func testActivityCarriesItsWholeTripleTogether() {
        let after = base().applying([
            .activityChanged(id: sessionID, activity: "waiting",
                             waitingFor: "permission prompt", subagentCount: 0)
        ])
        XCTAssertEqual(after.projects[0].sessions[0].activity, "waiting")
        XCTAssertEqual(after.projects[0].sessions[0].waitingFor, "permission prompt")
    }

    /// Statuslessness is a real state and has to be reachable by an event, or a tab whose
    /// agent exited would keep rendering the status it had when it died.
    func testActivityCanReturnToNil() {
        var snapshot = base().applying([
            .activityChanged(id: sessionID, activity: "busy", waitingFor: nil, subagentCount: 3)
        ])
        snapshot = snapshot.applying([
            .activityChanged(id: sessionID, activity: nil, waitingFor: nil, subagentCount: 0)
        ])
        XCTAssertNil(snapshot.projects[0].sessions[0].activity)
        XCTAssertEqual(snapshot.projects[0].sessions[0].subagentCount, 0)
    }

    func testUnreadFlips() {
        let after = base().applying([.unreadChanged(id: sessionID, isUnread: true)])
        XCTAssertTrue(after.projects[0].sessions[0].isUnread)
    }

    func testAMoveTakesTheSessionOutOfItsOldProject() {
        let other = UUID()
        var snapshot = base()
        snapshot.projects.append(WireProject(id: other, name: "b", path: "/w/b"))
        let after = snapshot.applying([.sessionMoved(id: sessionID, project: other, at: 0)])
        XCTAssertTrue(after.projects[0].sessions.isEmpty)
        XCTAssertEqual(after.projects[1].sessions.map(\.id), [sessionID])
    }

    // MARK: Projects

    func testAProjectIsAddedAndRemoved() {
        let newID = UUID()
        var snapshot = base().applying([
            .projectAdded(WireProject(id: newID, name: "b", path: "/w/b"), at: 0)
        ])
        XCTAssertEqual(snapshot.projects.map(\.id), [newID, projectID])
        snapshot = snapshot.applying([.projectRemoved(id: newID)])
        XCTAssertEqual(snapshot.projects.map(\.id), [projectID])
    }

    func testCollapseIsCarried() {
        XCTAssertTrue(
            base().applying([.projectCollapsed(id: projectID, isCollapsed: true)])
                .projects[0].isCollapsed
        )
    }

    func testProjectsAreReorderedByTheGivenOrder() {
        let other = UUID()
        var snapshot = base()
        snapshot.projects.append(WireProject(id: other, name: "b", path: "/w/b"))
        let after = snapshot.applying([.projectsReordered(order: [other, projectID])])
        XCTAssertEqual(after.projects.map(\.id), [other, projectID])
    }

    /// An order naming ids the client does not have — because a project was closed in the
    /// gap — must reorder what it can and keep the rest, not drop rows it was never told
    /// to remove.
    func testAReorderNamingUnknownIDsKeepsEveryProjectItDidNotMention() {
        let ghost = UUID()
        let after = base().applying([.projectsReordered(order: [ghost, projectID])])
        XCTAssertEqual(after.projects.map(\.id), [projectID])
    }

    func testSessionsAreReorderedWithinTheirProject() {
        let second = UUID()
        var snapshot = base()
        snapshot.projects[0].sessions.append(session(second, "two"))
        let after = snapshot.applying([
            .sessionsReordered(project: projectID, order: [second, sessionID])
        ])
        XCTAssertEqual(after.projects[0].sessions.map(\.id), [second, sessionID])
    }

    // MARK: Events about things we do not have

    /// The resume path guarantees this happens: a client that missed a removal, or that
    /// re-snapshotted mid-replay, sees events for ids it has never held. Every one must be
    /// inert.
    func testEveryEventAboutAnUnknownIDIsANoOp() {
        let ghost = UUID()
        let snapshot = base()
        let inert: [FleetEvent] = [
            .sessionRemoved(id: ghost),
            .renamed(id: ghost, title: "x", origin: .agent),
            .activityChanged(id: ghost, activity: "busy", waitingFor: nil, subagentCount: 0),
            .unreadChanged(id: ghost, isUnread: true),
            .sessionMoved(id: ghost, project: projectID, at: 0),
            .sessionAdded(session(UUID(), "x"), project: ghost, at: 0),
            .sessionsReordered(project: ghost, order: []),
            .projectRemoved(id: ghost),
            .projectCollapsed(id: ghost, isCollapsed: true)
        ]
        for event in inert {
            XCTAssertEqual(snapshot.applying([event]), snapshot, "\(event) was not inert")
        }
    }
}
