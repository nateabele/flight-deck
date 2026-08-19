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

    /// A session that appeared and vanished inside the gap collapses to its removal alone.
    /// The removal survives rather than the pair vanishing: see `survives(_:_:)` — the fold
    /// cannot know whether the client already held this id, and a removal it did not need is
    /// inert, while a removal it did need and never got is a phantom session.
    func testASessionAddedAndRemovedInTheGapCollapsesToItsRemoval() {
        let ghost = UUID()
        let events: [FleetEvent] = [
            .sessionAdded(session(ghost, "ghost"), project: projectID, at: 0),
            .activityChanged(id: ghost, activity: "busy", waitingFor: nil, subagentCount: 0),
            .sessionRemoved(id: ghost)
        ]
        XCTAssertEqual(FleetReplay.fold(events), [.sessionRemoved(id: ghost)])
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

    /// Reorders are state-dependent transforms, not last-write-wins fields: `reorder` leaves
    /// unmentioned ids "in place", so dropping an earlier reorder changes where the survivor
    /// puts everything it does not name. This is the sequence that proves it.
    func testTwoReordersStraddlingAnInsertionAreNotCollapsed() {
        let projA = UUID(), projB = UUID(), projC = UUID()
        let start = FleetSnapshot(projects: [
            WireProject(id: projA, name: "a", path: "/a"),
            WireProject(id: projB, name: "b", path: "/b")
        ])
        let events: [FleetEvent] = [
            .projectsReordered(order: [projB, projA]),
            .projectAdded(WireProject(id: projC, name: "c", path: "/c"), at: 1),
            .projectsReordered(order: [projA])
        ]
        XCTAssertEqual(
            start.applying(FleetReplay.fold(events)),
            start.applying(events),
            "the fold changed the resulting fleet"
        )
    }

    /// A project removed and re-added under the same id must survive intact. Dropping both
    /// events leaves the client holding the project's PRE-window sessions — stale data the
    /// server already deleted, which is a worse failure than an extra frame.
    func testAProjectRemovedAndReAddedInTheGapDoesNotResurrectStaleSessions() {
        let events: [FleetEvent] = [
            .projectRemoved(id: projectID),
            .projectAdded(WireProject(id: projectID, name: "fd", path: "/w/fd"), at: 0)
        ]
        assertFoldPreservesOutcome(events)
    }

    /// `sessionMoved` must stay positional for the same reason reorders must: its `at:`
    /// index resolves against the list as it stands when it runs. A regression that added it
    /// to `FoldKey` would reintroduce Bug 1 for moves, silently.
    func testSessionMovesAreNotCollapsedIntoTheLastOne() {
        let other = UUID()
        var start = base()
        start.projects.append(WireProject(id: other, name: "b", path: "/w/b"))
        let events: [FleetEvent] = [
            .sessionMoved(id: a, project: other, at: 0),
            .sessionMoved(id: b, project: other, at: 0),
            .sessionMoved(id: a, project: other, at: 1)
        ]
        XCTAssertEqual(FleetReplay.fold(events).count, 3,
                       "moves are positional, not last-write-wins")
        XCTAssertEqual(start.applying(FleetReplay.fold(events)), start.applying(events))
    }

    /// The fold sees events, never the snapshot they apply to, so it cannot tell a genesis
    /// add from a redundant one on a session the client already holds. It must therefore
    /// never use "an add appeared in this window" as licence to drop the removal — doing so
    /// leaves the client holding a session the server deleted.
    func testASessionRemovedAfterARedundantReAddIsStillRemoved() {
        let events: [FleetEvent] = [
            .sessionAdded(session(a, "a-again"), project: projectID, at: 0),
            .sessionRemoved(id: a)
        ]
        assertFoldPreservesOutcome(events)
    }

    func testAnEmptyGapFoldsToNothing() {
        XCTAssertTrue(FleetReplay.fold([FleetEvent]()).isEmpty)
    }
}
