import XCTest
@testable import FleetKit

/// The southbound prompt frame, and the two properties that are not obvious from its shape:
/// that it reads as one flat line in a packet dump, and that its decoder never throws over
/// its own payload.
final class PromptCommandCodingTests: XCTestCase {
    private let session = UUID()
    private let token = UUID()

    private func object(_ frame: ClientFrame) throws -> [String: Any] {
        let data = try JSONEncoder().encode(frame)
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// Flattened into the frame's own object, exactly as `markRead` and every `req` are: one
    /// command reads as one line, which is what makes a dump usable.
    func testAPromptEncodesAsOneFlatObject() throws {
        let json = try object(.cmd(cid: 41, .prompt(id: session, token: token, text: "ship it")))
        XCTAssertEqual(json["t"] as? String, "cmd")
        XCTAssertEqual(json["cid"] as? Int, 41)
        XCTAssertEqual(json["op"] as? String, "session.prompt")
        XCTAssertEqual(json["id"] as? String, session.uuidString)
        XCTAssertEqual(json["token"] as? String, token.uuidString)
        XCTAssertEqual(json["text"] as? String, "ship it")
        XCTAssertEqual(Set(json.keys), ["t", "cid", "op", "id", "token", "text"])
    }

    func testAPromptRoundTripsThroughClientFrame() throws {
        let sent = ClientFrame.cmd(cid: 9, .prompt(id: session, token: token, text: "a\n\tb"))
        let data = try JSONEncoder().encode(sent)
        XCTAssertEqual(try JSONDecoder().decode(ClientFrame.self, from: data), sent)
    }

    /// **The rule this file exists for.** `FleetSocketServer.onUndecodable` salvages
    /// `t == "req"` and nothing else, deliberately — so a `cmd` this build cannot parse takes
    /// the socket down with it. Refusing oversized or control-bearing text in the DECODER
    /// would therefore disconnect a phone over a paste, and the phone, with the same text
    /// still in its composer, would be one tap from doing it again. It decodes; the Mac
    /// refuses it with an `err` code the phone can render.
    ///
    /// The fixture breaks BOTH rules at once, so a decoder that enforced either one fails.
    func testTextTheMacWillRefuseStillDecodesRatherThanKillingTheSocket() throws {
        let hostile = "\u{1b}[201~" + String(repeating: "x", count: PromptText.maxCharacters + 1)
        let line = """
        {"t":"cmd","cid":3,"op":"session.prompt","id":"\(session.uuidString)",\
        "token":"\(token.uuidString)","text":\(String(data: try JSONEncoder().encode(hostile), encoding: .utf8)!)}
        """
        let frame = try JSONDecoder().decode(ClientFrame.self, from: Data(line.utf8))
        guard case .cmd(3, .prompt(session, token, let text)) = frame else {
            return XCTFail("a prompt whose text the Mac will refuse must still decode as a prompt")
        }
        XCTAssertEqual(text, hostile, "and it must arrive verbatim, not sanitised in transit")
    }

    /// The old two-case shape read `id` before it read `op`. This one reads `op` first, and
    /// this is the test that says the reorder did not move `markRead`.
    func testMarkReadStillDecodesFromTheShapeAlreadyOnTheWire() throws {
        let line = #"{"t":"cmd","cid":7,"op":"session.markRead","id":"\#(session.uuidString)"}"#
        XCTAssertEqual(
            try JSONDecoder().decode(ClientFrame.self, from: Data(line.utf8)),
            .cmd(cid: 7, .markRead(id: session))
        )
    }

    /// An unrecognised `op` throws, like `FleetRequest`'s and unlike `TimelineItem.Kind`'s:
    /// phone → Mac is executed rather than rendered, and there is no default that is not a
    /// wrong answer.
    func testAnUnknownOpStillThrows() {
        let line = #"{"t":"cmd","cid":7,"op":"session.detonate","id":"\#(session.uuidString)"}"#
        XCTAssertThrowsError(try JSONDecoder().decode(ClientFrame.self, from: Data(line.utf8)))
    }

    /// A prompt missing its token is not a prompt. Refused as the command it claimed to be,
    /// which is what reading `op` first buys.
    func testAPromptWithoutATokenThrows() {
        let line = #"{"t":"cmd","cid":7,"op":"session.prompt","id":"\#(session.uuidString)","text":"hi"}"#
        XCTAssertThrowsError(try JSONDecoder().decode(ClientFrame.self, from: Data(line.utf8)))
    }
}
