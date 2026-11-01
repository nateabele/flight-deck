import FleetKit
import XCTest
@testable import FlightDeck

final class PeerCLIArgumentsTests: XCTestCase {
    func testSendPreservesLiteralDashLedBody() throws {
        let request = try XCTUnwrap(PeerCLI.parse(["send", "target", "--notify-when-idle", "--", "--body"]))
        XCTAssertEqual(request.target, "target")
        XCTAssertEqual(request.message, "--body")
        XCTAssertTrue(request.notifyWhenIdle)
    }
    func testReceiveCursorAndOperatorSource() throws {
        let id = UUID()
        let request = try XCTUnwrap(PeerCLI.parse(["receive", "--after", "12", "--from", id.uuidString]))
        XCTAssertEqual(request.after, 12)
        XCTAssertEqual(request.source, id)
    }
    func testApprovalAndPermissionChangesAreNotAgentCLICommands() {
        XCTAssertThrowsError(try PeerCLI.parse(["approve", "id"]))
        XCTAssertThrowsError(try PeerCLI.parse(["inbound", "accept"]))
        XCTAssertThrowsError(try PeerCLI.parse(["receive", "--after", "-1"]))
        XCTAssertThrowsError(try PeerCLI.parse(["send", "target"]))
        XCTAssertThrowsError(try PeerCLI.parse(["list", "--notify-when-idle"]))
    }
}
