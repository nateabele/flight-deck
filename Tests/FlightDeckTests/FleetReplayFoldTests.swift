import XCTest
import FleetKit

final class FleetReplayFoldTests: XCTestCase {
    private let projectID = UUID()
    private let a = UUID()
    private let b = UUID()

    private func session(_ id: UUID, _ title: String) -> WireSession {
        WireSession(id: id, title: title, agent: "claude")
    }

    private func base() -> FleetSnapshot {
        FleetSnapshot(projects: [
            WireProject(id: projectID, name: "fd", path: "/w/fd",
                        sessions: [session(a, "a"), session(b, "b")])
        ])
    }

    /// The whole contract. Every other test in this file explains *how* the fold gets here;
    /// this one is what it is for.
    private func assertFoldPreservesOutcome(
        _ events: [FleetEvent], file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(
            base().applying(FleetReplay.fold(events)),
            base().applying(events),
            "the fold changed the resulting fleet",
            file: file, line: line
        )
    }

    func testRepeatedActivityCollapsesToTheLast() {
        let flaps: [FleetEvent] = (0..<50).map { i in
            .activityChanged(id: a, activity: i.isMultiple(of: 2) ? "busy" : "idle",
                             waitingFor: nil, subagentCount: 0)
        }
        XCTAssertEqual(FleetReplay.fold(flaps).count, 1)
        assertFoldPreservesOutcome(flaps)
    }

    func testRepeatedRenamesCollapseToTheLast() {
        let renames: [FleetEvent] = ["x", "y", "z"].map {
            .renamed(id: a, title: $0, origin: .agent)
        }
        XCTAssertEqual(FleetReplay.fold(renames), [.renamed(id: a, title: "z", origin: .agent)])
    }

    /// Per-session, not global: two sessions flapping must both survive, or the fold
    /// silently loses one of them.
    func testCollapsingIsPerSession() {
        let events: [FleetEvent] = [
            .activityChanged(id: a, activity: "busy", waitingFor: nil, subagentCount: 0),
            .activityChanged(id: b, activity: "busy", waitingFor: nil, subagentCount: 0),
            .activityChanged(id: a, activity: "idle", waitingFor: nil, subagentCount: 0)
        ]
        XCTAssertEqual(FleetReplay.fold(events).count, 2)
        assertFoldPreservesOutcome(events)
    }

    func testASessionRemovedInTheGapKeepsOnlyItsRemoval() {
        let events: [FleetEvent] = [
            .renamed(id: a, title: "x", origin: .user),
            .activityChanged(id: a, activity: "busy", waitingFor: nil, subagentCount: 4),
            .unreadChanged(id: a, isUnread: true),
            .sessionRemoved(id: a)
        ]
        XCTAssertEqual(FleetReplay.fold(events), [.sessionRemoved(id: a)])
        assertFoldPreservesOutcome(events)
    }

    /// A session that both appeared and vanished inside the gap never existed as far as the
    /// client is concerned. Emitting its removal would be harmless but emitting its *add*
    /// would not, and keeping the pair is pure noise.
    func testASessionAddedAndRemovedInTheGapDisappearsEntirely() {
        let ghost = UUID()
        let events: [FleetEvent] = [
            .sessionAdded(session(ghost, "ghost"), project: projectID, at: 0),
            .activityChanged(id: ghost, activity: "busy", waitingFor: nil, subagentCount: 0),
            .sessionRemoved(id: ghost)
        ]
        XCTAssertTrue(FleetReplay.fold(events).isEmpty)
        assertFoldPreservesOutcome(events)
    }

    func testAProjectRemovedInTheGapTakesItsOwnEventsWithIt() {
        let events: [FleetEvent] = [
            .projectCollapsed(id: projectID, isCollapsed: true),
            .sessionsReordered(project: projectID, order: [b, a]),
            .projectRemoved(id: projectID)
        ]
        XCTAssertEqual(FleetReplay.fold(events), [.projectRemoved(id: projectID)])
        assertFoldPreservesOutcome(events)
    }

    /// Order between *different* subjects is load-bearing: a session added to a project must
    /// not be folded ahead of the project's own arrival.
    func testRelativeOrderOfSurvivingEventsIsPreserved() {
        let newProject = UUID()
        let newSession = UUID()
        let events: [FleetEvent] = [
            .projectAdded(WireProject(id: newProject, name: "n", path: "/w/n"), at: 1),
            .sessionAdded(session(newSession, "n1"), project: newProject, at: 0),
            .renamed(id: newSession, title: "n2", origin: .user)
        ]
        XCTAssertEqual(FleetReplay.fold(events), events)
        assertFoldPreservesOutcome(events)
    }

    func testAnEmptyGapFoldsToNothing() {
        XCTAssertTrue(FleetReplay.fold([]).isEmpty)
    }
}
