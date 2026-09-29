import XCTest
@testable import FleetKit

final class IntakeWireCodingTests: XCTestCase {
    static let summary = WireIntakeSummary(
        id: UUID(), title: "Offline sync for job tickets", state: "shaping",
        needsAttention: false, preset: "fullPlan", now: "Refine 2", runStatus: "running",
        clockSince: Date(timeIntervalSinceReferenceDate: 800_000_000),
        agentsDone: 1, agentsTotal: 2, createdAt: Date(timeIntervalSinceReferenceDate: 799_000_000)
    )

    func testProjectIntakesRoundTripsWithItsDottedTag() throws {
        let event = FleetEvent.projectIntakes(project: UUID(), intakes: [Self.summary])
        let data = try JSONEncoder().encode(event)
        XCTAssertEqual(try JSONDecoder().decode(FleetEvent.self, from: data), event)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(json.contains("\"project.intakes\""), json)
    }

    func testProjectIntakesWithNilOmitsTheKey() throws {
        // nil = Flight Control not enabled for the project: absent, never `null`, so the
        // phone's `decodeIfPresent` reads exactly what an older Mac would send.
        let data = try JSONEncoder().encode(FleetEvent.projectIntakes(project: UUID(), intakes: nil))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(json["intakes"])
        XCTAssertEqual(try JSONDecoder().decode(FleetEvent.self, from: data),
                       .projectIntakes(project: try XCTUnwrap(UUID(uuidString: json["project"] as! String)), intakes: nil))
    }

    func testProjectIntakesNamesItsProjectAndNoSession() {
        let project = UUID()
        let event = FleetEvent.projectIntakes(project: project, intakes: [])
        XCTAssertEqual(event.projectID, project)
        XCTAssertNil(event.sessionID)
    }

    func testProjectIntakesReplacesTheProjectsListOnTheSnapshot() {
        let project = WireProject(id: UUID(), name: "larkOS", path: "/w/larkOS")
        var snapshot = FleetSnapshot(projects: [project])
        snapshot.apply(.projectIntakes(project: project.id, intakes: [Self.summary]))
        XCTAssertEqual(snapshot.projects[0].intakes, [Self.summary])
        snapshot.apply(.projectIntakes(project: project.id, intakes: nil))
        XCTAssertNil(snapshot.projects[0].intakes)
        // An unknown project is ignored, like every other project event.
        let before = snapshot
        snapshot.apply(.projectIntakes(project: UUID(), intakes: []))
        XCTAssertEqual(snapshot, before)
    }

    func testAProjectFromAnOlderMacDecodesWithNoIntakes() throws {
        let old = #"{"id":"\#(UUID().uuidString)","name":"a","path":"/a","isCollapsed":false,"sessions":[]}"#
        let project = try JSONDecoder().decode(WireProject.self, from: Data(old.utf8))
        XCTAssertNil(project.intakes)
    }

    func testAnUnknownStateStringStillDecodes() throws {
        var summary = Self.summary
        summary.state = "someFutureState"
        let data = try JSONEncoder().encode(summary)
        XCTAssertEqual(try JSONDecoder().decode(WireIntakeSummary.self, from: data).state, "someFutureState")
    }

    func testThePhoneAdvertisesFlightControl() {
        XCTAssertEqual(FleetCapability.flightControl, "flightControl")
        XCTAssertTrue(FleetCapability.supported.contains(FleetCapability.flightControl))
    }
}
