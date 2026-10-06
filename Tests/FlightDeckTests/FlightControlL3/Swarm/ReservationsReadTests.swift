import XCTest
@testable import FlightDeck

/// The reservations lane was a nil stub because no positive-path row had ever been seen
/// (observe-command-shapes notes). It is decoded now against the row captured in Task 11a, and
/// still degrades to nil — never a guess — on anything it cannot read.
final class ReservationsReadTests: XCTestCase {
    private func fixture(_ name: String, _ ext: String = "json") throws -> Data {
        try Data(contentsOf: XCTUnwrap(Bundle(for: Self.self).url(
            forResource: name, withExtension: ext, subdirectory: "Fixtures/FlightControlL3/Swarm")))
    }
    private struct Names: Decodable { let green: String; let blue: String; let pattern: String; let file: String }

    func testTheCapturedHeldReservationDecodes() throws {
        let names = try JSONDecoder().decode(Names.self, from: fixture("probe-names"))
        let rows = try XCTUnwrap(ReservationRows.decode(fixture("am-reservations-held")))
        let held = try XCTUnwrap(rows.first { $0.holder == names.green })
        XCTAssertEqual(held.file, names.pattern)
        XCTAssertNotEqual(held.since, .distantPast, "the row's timestamp must parse")
        XCTAssertEqual(held.waiters, [], "am names holders, never waiters")
    }

    /// The captured row carries no absolute time, only `"granted_at": "5s ago"`; it is anchored on
    /// the envelope's `_meta.timestamp` (captured 2026-10-05T17:31:29Z), so 5s before that.
    func testTheCapturedRowsRelativeGrantTimeIsAnchoredOnTheEnvelopeTimestamp() throws {
        let rows = try XCTUnwrap(ReservationRows.decode(fixture("am-reservations-held")))
        let anchor = try XCTUnwrap(AgentMailTime.parse("2026-10-05T17:31:29.444848+00:00"))
        XCTAssertEqual(try XCTUnwrap(rows.first).since.timeIntervalSince(anchor), -5, accuracy: 0.01)
    }

    func testRelativeTimes() {
        let now = Date(timeIntervalSince1970: 1_791_136_800)
        XCTAssertEqual(AgentMailTime.parseRelative("5s ago", from: now), now.addingTimeInterval(-5))
        XCTAssertEqual(AgentMailTime.parseRelative("12m ago", from: now), now.addingTimeInterval(-720))
        XCTAssertEqual(AgentMailTime.parseRelative("2h ago", from: now), now.addingTimeInterval(-7200))
        XCTAssertEqual(AgentMailTime.parseRelative("1d ago", from: now), now.addingTimeInterval(-86400))
        XCTAssertNil(AgentMailTime.parseRelative("soon", from: now))
    }

    func testAnEmptyAllActiveIsEmptyNotNil() {
        XCTAssertEqual(ReservationRows.decode(Data(#"{"all_active":[]}"#.utf8)), [])
    }

    func testUnreadableIsNil() {
        XCTAssertNil(ReservationRows.decode(Data("nope".utf8)))
        XCTAssertNil(ReservationRows.decode(Data(#"{"other":[]}"#.utf8)))
    }

    func testTheReadRunsTheProvenArgv() async throws {
        let fake = MultiRunner()
        fake.responses["am reservations --project"] = (String(decoding: try fixture("am-reservations-held"), as: UTF8.self), 0)
        let rows = await FlywheelReadCommands(runner: fake).reservations(project: "/tmp/p")
        XCTAssertNotNil(rows)
        XCTAssertEqual(fake.argv.last, ["am", "reservations", "--project", "/tmp/p", "--all", "--json"])
    }

    func testAgentMailTimes() {
        XCTAssertNotNil(AgentMailTime.parse("2026-09-22T16:57:34.483761Z"))
        XCTAssertNotNil(AgentMailTime.parse("2026-09-24T22:27:17.716028+00:00"))
        XCTAssertEqual(AgentMailTime.parse("2026-10-04T18:00:00Z"), Date(timeIntervalSince1970: 1_791_136_800))
        XCTAssertNil(AgentMailTime.parse("yesterday"))
    }
}
