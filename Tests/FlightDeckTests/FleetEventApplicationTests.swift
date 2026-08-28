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
                             waitingFor: "permission prompt", subagentCount: 4,
                             hasBackgroundWork: false)
        ])
        XCTAssertEqual(after.projects[0].sessions[0].activity, "waiting")
        XCTAssertEqual(after.projects[0].sessions[0].waitingFor, "permission prompt")
        // Non-default deliberately: `WireSession.subagentCount` defaults to 0, so asserting
        // 0 here would pass just as happily against an `apply` that never wrote the field.
        XCTAssertEqual(after.projects[0].sessions[0].subagentCount, 4)
    }

    /// The fold's other consumer of this event: a client applying `activityChanged` off a
    /// resumed replay has to land the flag too, not just a live snapshot fetch.
    func testActivityChangedCarriesBackgroundWorkThroughTheFold() {
        let after = base().applying([
            .activityChanged(id: sessionID, activity: "idle", waitingFor: nil,
                             subagentCount: 0, hasBackgroundWork: true)
        ])
        XCTAssertTrue(after.projects[0].sessions[0].hasBackgroundWork)
    }

    /// An older Mac's incremental update, not just its snapshot — `WireSession.init(from:)`
    /// isn't in play here at all, since `apply` mutates an already-decoded `WireSession` in
    /// place. Without its own mapping this event would land the pre-decomposition `"shell"`
    /// string straight into `activity` and reach `SessionStatusGlyph`'s "Unrecognized
    /// status" fallback.
    func testActivityChangedMapsLegacyShellToIdlePlusBackgroundWork() {
        let after = base().applying([
            .activityChanged(id: sessionID, activity: "shell", waitingFor: nil,
                             subagentCount: 0, hasBackgroundWork: false)
        ])
        XCTAssertEqual(after.projects[0].sessions[0].activity, "idle")
        XCTAssertTrue(after.projects[0].sessions[0].hasBackgroundWork)
    }

    /// Statuslessness is a real state and has to be reachable by an event, or a tab whose
    /// agent exited would keep rendering the status it had when it died.
    func testActivityCanReturnToNil() {
        var snapshot = base().applying([
            .activityChanged(id: sessionID, activity: "busy", waitingFor: nil, subagentCount: 3,
                             hasBackgroundWork: false)
        ])
        snapshot = snapshot.applying([
            .activityChanged(id: sessionID, activity: nil, waitingFor: nil, subagentCount: 0,
                             hasBackgroundWork: false)
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

    /// The case where remove-then-insert can invert the index: the session is taken out of
    /// the same array it is about to go back into, so a clamp computed before the removal
    /// would be off by one. Cross-project moves cannot catch this.
    func testAMoveWithinTheSameProjectReordersRatherThanCorrupting() {
        let second = UUID()
        var snapshot = base()
        snapshot.projects[0].sessions.append(session(second, "two"))
        let after = snapshot.applying([
            .sessionMoved(id: sessionID, project: projectID, at: 1)
        ])
        XCTAssertEqual(after.projects[0].sessions.map(\.id), [second, sessionID])
        XCTAssertEqual(after.projects[0].sessions.count, 2, "a move must not drop or duplicate")
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
            .activityChanged(id: ghost, activity: "busy", waitingFor: nil, subagentCount: 0,
                             hasBackgroundWork: false),
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
