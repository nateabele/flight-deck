import XCTest
@testable import HostKit

final class AdminWireTests: XCTestCase {
    private let slot = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let t10 = Date(timeIntervalSinceReferenceDate: 10)

    func testRequestShapesArePinned() throws {
        XCTAssertEqual(try HostWire.encode(AdminRequest.status), #"{"t":"status"}"#)
        XCTAssertEqual(try HostWire.encode(AdminRequest.arm), #"{"t":"arm"}"#)
        XCTAssertEqual(try HostWire.encode(AdminRequest.cancelArm), #"{"t":"cancelArm"}"#)
        XCTAssertEqual(try HostWire.encode(AdminRequest.listControllers), #"{"t":"ls"}"#)
        XCTAssertEqual(try HostWire.encode(AdminRequest.revoke(slot: slot)),
                       #"{"slot":"00000000-0000-0000-0000-000000000001","t":"revoke"}"#)
    }

    func testReplyShapesArePinned() throws {
        XCTAssertEqual(
            try HostWire.encode(AdminReply.status(paired: 2, armedUntil: t10, listeningPort: 4711, hostName: "mini")),
            #"{"armedUntil":10,"hostName":"mini","listeningPort":4711,"paired":2,"t":"status"}"#)
        XCTAssertEqual(
            try HostWire.encode(AdminReply.status(paired: 0, armedUntil: nil, listeningPort: nil, hostName: "mini")),
            #"{"hostName":"mini","paired":0,"t":"status"}"#)
        XCTAssertEqual(try HostWire.encode(AdminReply.armed(code: "AAAA-BBBB-CCCC", expiresAt: t10)),
                       #"{"code":"AAAA-BBBB-CCCC","expiresAt":10,"t":"armed"}"#)
        XCTAssertEqual(
            try HostWire.encode(AdminReply.controllers([AdminController(slot: slot, name: "laptop", pairedAt: t10)])),
            #"{"controllers":[{"name":"laptop","pairedAt":10,"slot":"00000000-0000-0000-0000-000000000001"}],"t":"controllers"}"#)
        XCTAssertEqual(try HostWire.encode(AdminReply.ok), #"{"t":"ok"}"#)
        XCTAssertEqual(try HostWire.encode(AdminReply.failed("nope")), #"{"message":"nope","t":"failed"}"#)
    }

    func testRoundTrip() throws {
        let reqs: [AdminRequest] = [.status, .arm, .cancelArm, .listControllers, .revoke(slot: slot)]
        for r in reqs { XCTAssertEqual(try HostWire.decode(AdminRequest.self, from: HostWire.encode(r)), r) }
        let reps: [AdminReply] = [
            .status(paired: 1, armedUntil: t10, listeningPort: 1, hostName: "h"),
            .status(paired: 1, armedUntil: nil, listeningPort: nil, hostName: "h"),
            .armed(code: "X", expiresAt: t10),
            .armed(code: "X", expiresAt: t10, pairingPort: 47411),
            .controllers([AdminController(slot: slot, name: "n", pairedAt: t10)]),
            .ok, .failed("x"),
        ]
        for r in reps { XCTAssertEqual(try HostWire.decode(AdminReply.self, from: HostWire.encode(r)), r) }
    }

    /// The pairing port rides on `armed` as an optional key, so the shape an older peer wrote
    /// (no `pairingPort`) still decodes, and a reply that names no port encodes exactly as
    /// before: a Linux `flightdeck-hostd pair` built before the field reads it unchanged.
    func testArmedCarriesAnOptionalPairingPort() throws {
        XCTAssertEqual(try HostWire.encode(AdminReply.armed(code: "AAAA-BBBB-CCCC", expiresAt: t10, pairingPort: 52001)),
                       #"{"code":"AAAA-BBBB-CCCC","expiresAt":10,"pairingPort":52001,"t":"armed"}"#)
        XCTAssertEqual(try HostWire.decode(AdminReply.self, from: #"{"code":"X","expiresAt":10,"t":"armed"}"#),
                       .armed(code: "X", expiresAt: t10, pairingPort: nil))
        XCTAssertEqual(try HostWire.decode(AdminReply.self, from: #"{"code":"X","expiresAt":10,"pairingPort":47411,"t":"armed"}"#),
                       .armed(code: "X", expiresAt: t10, pairingPort: 47411))
    }

    func testUnknownTagThrows() {
        XCTAssertThrowsError(try HostWire.decode(AdminRequest.self, from: #"{"t":"future"}"#))
    }
}
