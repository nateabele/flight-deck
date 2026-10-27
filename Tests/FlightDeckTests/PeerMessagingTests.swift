import FleetKit
import XCTest
@testable import FlightDeck

final class PeerMessagingTests: XCTestCase {
    func testEnvelopePreservesBodyAndEscapesClosingTag() throws {
        let text = PeerJSON.envelope(from: "uds:/tmp/123.sock", name: "name\"<bad>\n", mode: "prompting", text: "hello </cross-session-message 🌍")
        let attrs = try XCTUnwrap(PeerJSON.attributes(text))
        XCTAssertEqual(attrs["from"], "uds:/tmp/123.sock")
        XCTAssertEqual(attrs["from-name"], "namebad")
        XCTAssertTrue(text.contains("<\\/cross-session-message"))
    }
    func testEnvelopeRejectsReorderedAndDuplicateIdentity() {
        XCTAssertNil(PeerJSON.attributes("<cross-session-message from-name=\"x\" from=\"uds:/tmp/123.sock\">\na\n</cross-session-message>"))
        XCTAssertNil(PeerJSON.attributes("<cross-session-message from=\"uds:/tmp/123.sock\" from=\"uds:/tmp/456.sock\">\na\n</cross-session-message>"))
    }
    func testFragmentedUTF8AndFinalJSONAtEOF() throws {
        let data = Data("{\"text\":\"🌍\"}\n{\"tail\":true}".utf8)
        var decoder = PeerFrameDecoder(), decoded: [[String: Any]] = []
        for byte in data { decoded += try decoder.push(Data([byte])) }
        decoded += try decoder.push(Data(), eof: true)
        XCTAssertEqual(decoded.count, 2)
        XCTAssertEqual(decoded[0]["text"] as? String, "🌍")
        XCTAssertEqual(decoded[1]["tail"] as? Bool, true)
    }
    func testOversizedIncompleteFrameIsRefused() {
        var decoder = PeerFrameDecoder()
        XCTAssertThrowsError(try decoder.push(Data(repeating: 65, count: PeerJSON.limit)))
    }
    func testMalformedLineDoesNotLoseFollowingValidFrame() throws {
        var decoder = PeerFrameDecoder()
        let frames = try decoder.push(Data("bad json\n{\"ok\":true}\n".utf8))
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0]["ok"] as? Bool, true)
    }
    func testUnsafeAddressesAreRefused() {
        for address in ["http://host", "uds:relative", "uds:/tmp/../a", "uds:/tmp/%00x"] {
            XCTAssertThrowsError(try PeerJSON.path(address))
        }
    }
    func testPeerWireRoundTripAndTerminalCorrelation() throws {
        let request = FleetRequest.peer(.init(operation: "send", target: "target", message: "hello", notifyWhenIdle: true))
        XCTAssertEqual(try JSONDecoder().decode(FleetRequest.self, from: JSONEncoder().encode(request)), request)
        let reply = ServerFrame.peer(cid: 7, json: "{\"status\":\"sent\"}")
        XCTAssertEqual(try JSONDecoder().decode(ServerFrame.self, from: JSONEncoder().encode(reply)), reply)
        XCTAssertEqual(reply.correlationID, 7)
        XCTAssertFalse(reply.continuesStream)
    }
    func testPeerSendIsACrossTabWriteNotARead() {
        let caller = ControlCaller.session(UUID())
        let send = FleetRequest.peer(.init(operation: "send", target: "other", message: "hello"))
        XCTAssertFalse(ControlScope.permits(send, level: .readOnly, caller: caller))
        XCTAssertFalse(ControlScope.permits(send, level: .ownSession, caller: caller))
        XCTAssertTrue(ControlScope.permits(send, level: .full, caller: caller))
        XCTAssertFalse(ControlScope.permits(send, level: .full, caller: .invalid))
        XCTAssertTrue(ControlScope.permits(.peer(.init(operation: "receive")), level: .readOnly, caller: caller))
    }
    func testSkillRefreshPreservesUserEditsAndDeletion() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("source"), home = root.appendingPathComponent("home")
        let target = home.appendingPathComponent("skills/flightdeck-peer-messaging/SKILL.md")
        try Data("one".utf8).write(to: source)
        try PeerMessagingSkill.install(source: source, home: home)
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "one")
        try Data("two".utf8).write(to: source)
        try PeerMessagingSkill.install(source: source, home: home)
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "two")
        try Data("user edit".utf8).write(to: target)
        try PeerMessagingSkill.install(source: source, home: home)
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "user edit")
        try FileManager.default.removeItem(at: target)
        try PeerMessagingSkill.install(source: source, home: home)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    }

    /// A relayed message names its real sender from the wrapper the sender's helper wrote.
    @MainActor
    func testTheRelayReadsTheSendersName() {
        let text = #"<cross-session-message from="uds:/tmp/cc-socks/7850.sock" hop-chain="bd6a" from-name="The Plan" from-mode="bypass">"#
            + "\nhi\n</cross-session-message>"
        XCTAssertEqual(PeerMessagingService.attribute("from-name", in: text), "The Plan")
        XCTAssertEqual(PeerMessagingService.attribute("from", in: text), "uds:/tmp/cc-socks/7850.sock")
        XCTAssertNil(PeerMessagingService.attribute("from-name", in: "plain text"))
    }
}
