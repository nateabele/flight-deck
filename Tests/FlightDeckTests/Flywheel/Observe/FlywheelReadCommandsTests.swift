import XCTest
@testable import FlightDeck

final class FlywheelReadCommandsTests: XCTestCase {
    func testAgentsBuildsScopedArgvAndParses() async {
        let fake = MultiRunner()
        fake.responses["am agents list"] = (#"[{"name":"BlueFalcon"},{"name":"GoldViper"}]"#, 0)
        let rc = FlywheelReadCommands(runner: fake, amPath: "am", brPath: "br")
        let agents = await rc.agents(project: "/tmp/p")
        XCTAssertEqual(agents?.map(\.name), ["BlueFalcon", "GoldViper"])
        XCTAssertEqual(fake.argv.first, ["am", "agents", "list", "/tmp/p", "--json"])
    }

    func testInProgressBeadsUnwrapsIssuesEnvelope() async {
        let fake = MultiRunner()
        // Keyed "br list --status", not "br list": the real argv's prefix(2) is
        // ["list","--status"], per Task 1's confirmed `br --db <db> list --status
        // in_progress --json` shape (findings doc, 2026-09-24).
        fake.responses["br list --status"] =
            (#"{"issues":[{"id":"bd-142","title":"refactor auth","status":"in_progress","assignee":"BlueFalcon"}]}"#, 0)
        let rc = FlywheelReadCommands(runner: fake, amPath: "am", brPath: "br")
        let beads = await rc.inProgressBeads(project: "/tmp/p")
        XCTAssertEqual(beads?.first?.id, "bd-142")
        XCTAssertEqual(beads?.first?.assignee, "BlueFalcon")
        XCTAssertEqual(fake.argv.first, ["br", "list", "--status", "in_progress", "--json", "--db", "/tmp/p/.beads/beads.db"])
    }

    func testMissingCommandDegradesToNilNotThrow() async {
        let fake = MultiRunner()                 // every response defaults to exit 127
        let rc = FlywheelReadCommands(runner: fake, amPath: "am", brPath: "br")
        let agents = await rc.agents(project: "/tmp/p")
        XCTAssertNil(agents, "a non-zero exit must degrade to nil, not throw or crash")
    }

    func testGarbageStdoutDegradesToNil() async {
        let fake = MultiRunner()
        fake.responses["am agents list"] = ("not json at all", 0)
        let rc = FlywheelReadCommands(runner: fake, amPath: "am", brPath: "br")
        let agents = await rc.agents(project: "/tmp/p")
        XCTAssertNil(agents)
    }

    /// `events` is still unconfirmed at the row level (observe-command-shapes notes), so it stays
    /// a nil-stub. `reservations` and `depEdges` are real since L3-S (ReservationsReadTests,
    /// DepEdgesReadTests).
    func testEventsStayANilStub() async {
        let fake = MultiRunner()
        fake.responses["am inbox-events --agent"] = (#"{"events":[],"next_cursor":0,"has_more":false}"#, 0)
        let rc = FlywheelReadCommands(runner: fake, amPath: "am", brPath: "br")
        let events = await rc.events(project: "/tmp/p", after: "0")
        XCTAssertNil(events)
    }
}
