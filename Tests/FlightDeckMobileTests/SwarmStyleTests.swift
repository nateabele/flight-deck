import FleetKit
import XCTest
@testable import FlightDeckMobile

/// The phone draws a swarm agent's chips on its existing row and a card per project (spec §8);
/// every string the views show comes from here.
final class SwarmStyleTests: XCTestCase {
    private let session = UUID()
    private var swarm: WireSwarm {
        WireSwarm(state: "paused", summary: "swarm paused · 1/3", banner: "Swarm paused after restart · Resume",
                  agents: [WireSwarmAgent(session: session, task: "fx-1", kind: "tests", model: "opus", accountName: "Work",
                                          state: "working", marker: nil, contested: true, handoffPending: false)],
                  meters: [WireSwarmMeter(pool: "claude-subs", accountName: "Work", utilization: 0.835, state: "overSoft"),
                           WireSwarmMeter(pool: "local", accountName: "slot 1", utilization: nil, state: "unknown")],
                  waiting: 0)
    }

    func testAProjectionFrameDecodesAndFolds() throws {
        let project = UUID()
        let frame = try JSONEncoder().encode(ServerFrame.event(seq: 4, .projectSwarm(project: project, swarm: swarm)))
        guard case .event(_, let event) = try JSONDecoder().decode(ServerFrame.self, from: frame) else { return XCTFail() }
        var fleet = FleetSnapshot(projects: [WireProject(id: project, name: "p", path: "/p")])
        fleet.apply(event)
        XCTAssertEqual(SwarmStyle.agent(for: session, in: fleet.projects[0])?.task, "fx-1")
        XCTAssertNil(SwarmStyle.agent(for: UUID(), in: fleet.projects[0]))
    }

    func testChipsAndCard() throws {
        let agent = try XCTUnwrap(swarm.agents.first)
        XCTAssertEqual(SwarmStyle.chip(agent), "fx-1 · tests")
        XCTAssertEqual(SwarmStyle.detail(agent), "opus · Work")
        XCTAssertEqual(SwarmStyle.cardTitle(swarm), "Swarm paused after restart · Resume")
        XCTAssertTrue(SwarmStyle.canResume(swarm))
        XCTAssertFalse(SwarmStyle.canPause(swarm))
        XCTAssertEqual(swarm.meters.map(SwarmStyle.meterText), ["claude-subs · Work · 84%", "local · slot 1 · no reading"])
    }
}
