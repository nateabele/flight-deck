import XCTest
@testable import FleetKit
@testable import FlightDeck

/// The four `intake.*` commands: wire shape and scope. Their behavior is `IntakeService`'s
/// (`IntakePhoneCommandTests`); the service arm is `IntakeSteerCommandServiceTests`.
final class IntakeCommandCodingTests: XCTestCase {
    private let id = UUID(), token = UUID(), noteID = UUID()

    private func roundTrip(_ command: FleetCommand, op: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let data = try JSONEncoder().encode(command)
        XCTAssertEqual(try JSONDecoder().decode(FleetCommand.self, from: data), command, file: file, line: line)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["op"] as? String, op, file: file, line: line)
    }

    func testTapeRoundTripsWithAndWithoutAStage() throws {
        try roundTrip(.intakeTape(id: id, token: token, command: "pause", stage: nil), op: "intake.tape")
        try roundTrip(.intakeTape(id: id, token: token, command: "extend", stage: "refine"), op: "intake.tape")
    }

    func testTapeWithoutAStageOmitsTheKey() throws {
        let data = try JSONEncoder().encode(FleetCommand.intakeTape(id: id, token: token, command: "step", stage: nil))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(json["stage"])
    }

    func testDefaultPlayRoundTrips() throws {
        try roundTrip(.intakeDefaultPlay(id: id, token: token, mode: "step"), op: "intake.defaultPlay")
    }

    func testNoteRoundTripsWithAndWithoutItsAnchor() throws {
        try roundTrip(.intakeNote(id: id, token: token, noteID: noteID, kind: "comment", text: "why?",
                                  checkpoint: nil, block: nil, quote: nil), op: "intake.note")
        try roundTrip(.intakeNote(id: id, token: token, noteID: noteID, kind: "comment", text: "why?",
                                  checkpoint: 2, block: 3, quote: "the phrase"), op: "intake.note")
    }

    func testRemoveNoteRoundTrips() throws {
        try roundTrip(.intakeRemoveNote(id: id, token: token, noteID: noteID), op: "intake.removeNote")
    }

    func testScopeIsFleetWideForAllFour() {
        let me = UUID()
        let all: [FleetCommand] = [
            .intakeTape(id: id, token: token, command: "pause", stage: nil),
            .intakeDefaultPlay(id: id, token: token, mode: "step"),
            .intakeNote(id: id, token: token, noteID: noteID, kind: "comment", text: "x",
                        checkpoint: nil, block: nil, quote: nil),
            .intakeRemoveNote(id: id, token: token, noteID: noteID)]
        for c in all {
            XCTAssertFalse(ControlScope.permits(c, level: .ownSession, caller: .session(me)), "\(c)")
            XCTAssertFalse(ControlScope.permits(c, level: .ownSession, caller: .session(id)), "\(c)")
            XCTAssertTrue(ControlScope.permits(c, level: .full, caller: .session(me)), "\(c)")
        }
    }
}
