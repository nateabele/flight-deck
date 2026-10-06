import XCTest
import IntakeKit
@testable import FlightDeck

/// The handoff's shortcut: release already decodes `br graph --all --json` live, so Observe's
/// dependency lane reuses that decoder instead of the never-probed `br dep list`.
final class DepEdgesReadTests: XCTestCase {
    private func graph() throws -> String {
        String(decoding: try Data(contentsOf: XCTUnwrap(Bundle(for: Self.self).url(
            forResource: "br-graph-all", withExtension: "json", subdirectory: "Fixtures/Intake"))), as: UTF8.self)
    }

    func testDecodeEdgesIsTheGraphHalfOfTheSnapshot() throws {
        XCTAssertEqual(try GraphSnapshot.decodeEdges(graph: Data(try graph().utf8)),
                       [DepEdge(dependent: "t-5mi", dependency: "t-lqw")])
    }

    func testDepEdgesReadsGraphAll() async throws {
        let fake = MultiRunner()
        fake.responses["br graph --all"] = (try graph(), 0)
        let edges = await FlywheelReadCommands(runner: fake).depEdges(project: "/tmp/p")
        XCTAssertEqual(edges, [FlywheelReadCommands.RawDepEdge(from: "t-5mi", to: "t-lqw")])
        XCTAssertEqual(fake.argv.last, ["br", "graph", "--all", "--json", "--db", "/tmp/p/.beads/beads.db"])
    }

    func testAFailingGraphDegradesToNil() async {
        let edges = await FlywheelReadCommands(runner: MultiRunner()).depEdges(project: "/tmp/p")
        XCTAssertNil(edges)
    }
}
