import XCTest
import FleetKit
@testable import FlightDeck

/// The swarm's phone surface (spec §8): one projection per project and four commands, each with
/// a fixed wire spelling, and an older Mac's snapshot (no `swarm` key) still decodes.
final class SwarmWireTests: XCTestCase {
    private let swarm = WireSwarm(state: "running", summary: "swarm 2/3 · 1 waiting", banner: nil,
                                  agents: [WireSwarmAgent(session: UUID(), task: "fx-1", kind: "tests", model: "opus",
                                                          accountName: "Work", state: "working", marker: nil,
                                                          contested: true, handoffPending: false)],
                                  meters: [WireSwarmMeter(pool: "claude-subs", accountName: "Work", utilization: 0.4, state: "underSoft")],
                                  waiting: 1)

    func testTheProjectionEventRoundTrips() throws {
        let project = UUID()
        let data = try JSONEncoder().encode(FleetEvent.projectSwarm(project: project, swarm: swarm))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["t"] as? String, "project.swarm")
        XCTAssertEqual(try JSONDecoder().decode(FleetEvent.self, from: data), .projectSwarm(project: project, swarm: swarm))
        let cleared = try JSONEncoder().encode(FleetEvent.projectSwarm(project: project, swarm: nil))
        XCTAssertNil((try JSONSerialization.jsonObject(with: cleared) as? [String: Any])?["swarm"], "nil is absent, not null")
    }

    func testAnOlderMacsProjectDecodesWithoutASwarm() throws {
        let json = #"{"id":"\#(UUID().uuidString)","name":"p","path":"/p","isCollapsed":false,"sessions":[]}"#
        XCTAssertNil(try JSONDecoder().decode(WireProject.self, from: Data(json.utf8)).swarm)
    }

    func testTheCommandsHaveTheirWireSpellings() throws {
        let project = UUID(), session = UUID()
        let cases: [(FleetCommand, String)] = [(.swarmPause(project: project), "swarm.pause"),
                                               (.swarmResume(project: project), "swarm.resume"),
                                               (.handoffConfirm(id: session), "handoff.confirm"),
                                               (.handoffDecline(id: session), "handoff.decline")]
        for (command, op) in cases {
            let data = try JSONEncoder().encode(command)
            XCTAssertEqual((try JSONSerialization.jsonObject(with: data) as? [String: Any])?["op"] as? String, op)
            XCTAssertEqual(try JSONDecoder().decode(FleetCommand.self, from: data), command)
        }
    }

    func testTheSnapshotFoldsTheEvent() {
        let project = UUID()
        var fleet = FleetSnapshot(projects: [WireProject(id: project, name: "p", path: "/p")])
        fleet.apply(.projectSwarm(project: project, swarm: swarm))
        XCTAssertEqual(fleet.projects[0].swarm, swarm)
        fleet.apply(.projectSwarm(project: project, swarm: nil))
        XCTAssertNil(fleet.projects[0].swarm)
    }

    @MainActor
    func testOnlyAPeerThatClaimsSwarmIsSentTheEvent() {
        XCTAssertEqual(FleetService.requiredCapability(for: .projectSwarm(project: UUID(), swarm: nil)), FleetCapability.swarm)
        XCTAssertTrue(FleetCapability.supported.contains("swarm"))
    }

    @MainActor
    func testAScopedAgentCannotSteerTheSwarm() {
        let me = UUID()
        XCTAssertFalse(ControlScope.permits(.swarmPause(project: UUID()), level: .ownSession, caller: .session(me)))
        XCTAssertFalse(ControlScope.permits(.handoffConfirm(id: me), level: .ownSession, caller: .session(me)))
        XCTAssertTrue(ControlScope.permits(.swarmResume(project: UUID()), level: .full, caller: .session(me)))
    }
}
