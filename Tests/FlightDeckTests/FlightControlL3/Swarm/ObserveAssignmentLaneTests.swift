import XCTest
import IntakeKit
@testable import FlightDeck

/// Spec §6: a new Assignment lane, first, with the task, kind, harness/model/knobs, the routing
/// source and reason, the account, and the hand-off history with links to the other tabs.
@MainActor
final class ObserveAssignmentLaneTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private let agent = FlywheelProjection.Agent(name: "BlueLake", bead: nil, status: .active, holds: [], waitsOn: [],
                                                 lastEventAt: nil, stalledSince: nil)

    func testWithoutAnAssignmentTheLanesAreUnchanged() {
        XCTAssertEqual(ObserveLaneModel.lanes(for: agent, unavailable: []).map(\.lane),
                       [.workingOn, .files, .dependency, .activity])
    }

    func testTheAssignmentLaneComesFirstWithItsLinks() {
        let prev = UUID()
        let detail = SwarmAssignmentDetail(lines: ["task fx-1"], links: [ObserveLaneLink(title: "← GreenFox", session: prev)])
        let rows = ObserveLaneModel.lanes(for: agent, assignment: detail, unavailable: [])
        XCTAssertEqual(rows.map(\.lane), [.assignment, .workingOn, .files, .dependency, .activity])
        XCTAssertEqual(rows[0].title, "Assignment")
        XCTAssertEqual(rows[0].detail, "task fx-1")
        XCTAssertEqual(rows[0].links, [ObserveLaneLink(title: "← GreenFox", session: prev)])
    }

    func testTheDetailLines() {
        var block = SwarmFixtures.block(kind: "snapshot-tests")
        block.knobs = ["effort": "high"]
        block.source = AssignmentSource(by: .rule, ruleId: "r3", reason: "test-authoring 0.8 → codex", at: now)
        let lease = AccountLease(pool: "codex-subs", account: AccountRef(agent: .codex, id: UUID(), label: "Work"))
        var me = SwarmAgentRecord(session: UUID(), agentName: "BlueLake", block: block, lease: lease, task: "fx-1",
                                  state: .working, stateSince: now)
        let previous = SwarmAgentRecord(session: UUID(), agentName: "GreenFox", block: block, lease: nil, task: nil,
                                        state: .handedOff, stateSince: now)
        me.handedOffFrom = previous.session
        let detail = SwarmAnnotations.assignment(
            agent: me, headroom: AccountHeadroom(account: lease.account, worstUtilization: 0.62, state: .underSoft, resetsAt: nil),
            previous: previous, next: nil, lastActive: now.addingTimeInterval(-240), now: now)
        XCTAssertEqual(detail.lines, [
            "task fx-1 · kind snapshot-tests",
            "codex · gpt-6-sol · effort=high · pool codex-subs",
            "routed by rule r3 — test-authoring 0.8 → codex",
            "account Work · 62%",
            "handed off from GreenFox",
            "active 4 min ago",
        ])
        XCTAssertEqual(detail.links, [ObserveLaneLink(title: "← GreenFox", session: previous.session)])
    }

    func testAPinnedBlockSaysSo() {
        let block = SwarmFixtures.block(pinned: true)
        let me = SwarmAgentRecord(session: UUID(), agentName: "A", block: block, lease: nil, task: nil, state: .idle, stateSince: now)
        let lines = SwarmAnnotations.assignment(agent: me, headroom: nil, previous: nil, next: nil, lastActive: nil, now: now).lines
        XCTAssertTrue(lines.contains("pinned by hand — fixture"))
        XCTAssertTrue(lines.contains("no account lease"))
        XCTAssertEqual(lines.first, "no task · kind tests")
    }
}
