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

    /// `reservations`, `depEdges`, and `events` all decode shapes Task 1's probe could not
    /// confirm at the row level (see docs/superpowers/notes/2026-09-24-observe-command-shapes.md),
    /// so they ship as nil-stubs rather than guessed decoders — confirm that's what a caller
    /// actually gets, independent of the runner's response.
    func testUnconfirmedShapesDegradeToNilStub() async {
        let fake = MultiRunner()
        fake.responses["am reservations --project"] = (#"{"all_active":[]}"#, 0)
        fake.responses["am inbox-events --agent"] = (#"{"events":[],"next_cursor":0,"has_more":false}"#, 0)
        let rc = FlywheelReadCommands(runner: fake, amPath: "am", brPath: "br")
        let reservations = await rc.reservations(project: "/tmp/p")
        let depEdges = await rc.depEdges(project: "/tmp/p")
        let events = await rc.events(project: "/tmp/p", after: "0")
        XCTAssertNil(reservations)
        XCTAssertNil(depEdges)
        XCTAssertNil(events)
    }
}
