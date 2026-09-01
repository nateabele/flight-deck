import XCTest
@testable import FleetKit

/// The one frame this feature adds, and the properties that are not obvious from its shape:
/// that it names a choice rather than carrying one, that `deny` carries nothing at all, and
/// that the vocabulary already on the wire still decodes beside it.
final class AnswerFrameCodingTests: XCTestCase {
    private let session = UUID()
    private let token = UUID()

    private func object(_ frame: ClientFrame) throws -> [String: Any] {
        let data = try JSONEncoder().encode(frame)
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// Flattened into the frame's own object, exactly as `markRead` and `session.prompt` are:
    /// one command reads as one line, which is what makes a packet dump usable.
    func testAnOptionAnswerReadsAsOneFlatObject() throws {
        let json = try object(.cmd(cid: 41, .answerPrompt(
            id: session, token: token, call: "toolu_A",
            answer: .option(index: 1, label: "Speaking 10 languages")
        )))
        XCTAssertEqual(json["t"] as? String, "cmd")
        XCTAssertEqual(json["op"] as? String, "prompt.answer")
        XCTAssertEqual(json["call"] as? String, "toolu_A")
        XCTAssertEqual(json["answer"] as? String, "option")
        XCTAssertEqual(json["index"] as? Int, 1)
        XCTAssertEqual(json["label"] as? String, "Speaking 10 languages")
        XCTAssertEqual(
            Set(json.keys), ["t", "cid", "op", "id", "token", "call", "answer", "index", "label"]
        )
    }

    /// **Deny carries nothing, and that is the point.** It is delivered as a single Escape on
    /// the Mac with no screen read, so there is nothing for it to name and nothing a client
    /// could get wrong about it.
    func testDenyCarriesNoIndexAndNoLabel() throws {
        let json = try object(.cmd(cid: 4, .answerPrompt(
            id: session, token: token, call: "toolu_A", answer: .deny
        )))
        XCTAssertEqual(json["answer"] as? String, "deny")
        XCTAssertNil(json["index"])
        XCTAssertNil(json["label"])
    }

    /// **Allow carries nothing either**, because it means "the dialog's first row" and the Mac
    /// is the only thing entitled to say which row that is. A phone that could send an index
    /// here could reach the middle rows — "Yes, and don't ask again for Bash commands in
    /// /Users/nate" — which is a durable grant this design puts out of reach by construction.
    func testAllowCarriesNoIndexAndNoLabel() throws {
        let json = try object(.cmd(cid: 4, .answerPrompt(
            id: session, token: token, call: "toolu_A", answer: .allow
        )))
        XCTAssertEqual(json["answer"] as? String, "allow")
        XCTAssertNil(json["index"])
        XCTAssertNil(json["label"])
    }

    /// **The guard on the security property, and the only test that fails when a case
    /// appears.** `PromptAnswer`'s cases are what makes "Yes, and don't ask again for Bash
    /// commands in /Users/nate" unnameable from a phone; every other test here would stay
    /// green beside a `.allowAlways` nobody sent yet. `Tag` is the vocabulary actually on the
    /// wire, so counting it catches a case added to the enum and to the codec both.
    ///
    /// **`answers` was added deliberately and cannot reach that row.** It names options inside
    /// an `AskUserQuestion`, and `SessionStore.answerPrompt` refuses it for anything but
    /// `.question` — a permission dialog has no `questions` for its indices to mean anything
    /// in, so there is no path from this case to a permission dialog's rows at all. Each index
    /// is additionally checked against the transcript's own option list and its label before a
    /// single arrow is counted. Updating this list is a decision, not a formality: read
    /// `SessionStore.answerPrompt` before you change the expectation again.
    func testThereIsNoCaseThatReachesTheDontAskAgainRow() {
        XCTAssertEqual(PromptAnswer.Tag.allCases.map(\.rawValue),
                       ["option", "allow", "deny", "answers"])
    }

    /// The reason `answers` is safe, asserted rather than argued: it is refused outright
    /// against a permission dialog, which is the only shape with a durable-grant row.
    func testAnAnswerSetIsRefusedAgainstAPermissionDialog() {
        XCTAssertNil(
            AnswerPlan.plan(for: [], answers: []),
            "no questions, no plan — a permission dialog offers nothing for an index to index"
        )
    }

    func testEachAnswerRoundTripsThroughClientFrame() throws {
        for answer: PromptAnswer in [
            .option(index: 0, label: "Yes"), .allow, .deny,
            .answers([[.init(index: 1, label: "Go")], [.init(index: 0, label: "Vim")]]),
        ] {
            let sent = ClientFrame.cmd(cid: 9, .answerPrompt(
                id: session, token: token, call: "toolu_A", answer: answer
            ))
            let data = try JSONEncoder().encode(sent)
            XCTAssertEqual(try JSONDecoder().decode(ClientFrame.self, from: data), sent)
        }
    }

    func testAPromptStillDecodesFromTheShapeAlreadyOnTheWire() throws {
        let line = """
        {"t":"cmd","cid":7,"op":"session.prompt","id":"\(session.uuidString)",\
        "token":"\(token.uuidString)","text":"hi"}
        """
        XCTAssertEqual(
            try JSONDecoder().decode(ClientFrame.self, from: Data(line.utf8)),
            .cmd(cid: 7, .prompt(id: session, token: token, text: "hi"))
        )
    }

    func testMarkReadStillDecodesFromTheShapeAlreadyOnTheWire() throws {
        let line = #"{"t":"cmd","cid":7,"op":"session.markRead","id":"\#(session.uuidString)"}"#
        XCTAssertEqual(
            try JSONDecoder().decode(ClientFrame.self, from: Data(line.utf8)),
            .cmd(cid: 7, .markRead(id: session))
        )
    }

    /// An answer with no call id is an intent with nothing to apply it to, and accepting it
    /// would act on whatever happened to be up. Refused as the command it claimed to be,
    /// which is what reading `op` before `id` buys.
    func testAnAnswerWithoutACallIDThrows() {
        let line = """
        {"t":"cmd","cid":7,"op":"prompt.answer","id":"\(session.uuidString)",\
        "token":"\(token.uuidString)","answer":"deny"}
        """
        XCTAssertThrowsError(try JSONDecoder().decode(ClientFrame.self, from: Data(line.utf8)))
    }

    /// An `option` with no index is not an option. The three-case codec must not silently read
    /// it as `allow`.
    func testAnOptionAnswerWithoutAnIndexThrows() {
        let line = """
        {"t":"cmd","cid":7,"op":"prompt.answer","id":"\(session.uuidString)",\
        "token":"\(token.uuidString)","call":"toolu_A","answer":"option","label":"Yes"}
        """
        XCTAssertThrowsError(try JSONDecoder().decode(ClientFrame.self, from: Data(line.utf8)))
    }

    /// **An unknown answer throws, unlike `TimelineItem.Kind`'s decode-unknown rule, and the
    /// difference is direction.** Phone → Mac is executed, not rendered; there is no fallback
    /// for "an intent I do not understand" that is not a wrong answer, and here a wrong answer
    /// is a keystroke in a live terminal.
    func testAnUnknownAnswerThrows() {
        let line = """
        {"t":"cmd","cid":7,"op":"prompt.answer","id":"\(session.uuidString)",\
        "token":"\(token.uuidString)","call":"toolu_A","answer":"allow_always"}
        """
        XCTAssertThrowsError(try JSONDecoder().decode(ClientFrame.self, from: Data(line.utf8)))
    }

    func testAnUnknownOpStillThrows() {
        let line = #"{"t":"cmd","cid":7,"op":"session.detonate","id":"\#(session.uuidString)"}"#
        XCTAssertThrowsError(try JSONDecoder().decode(ClientFrame.self, from: Data(line.utf8)))
    }
}
