import XCTest
import IntakeKit

/// `HarnessOutput.parse(.grok, …)` over grok's `streaming-messages-json` (grok/gemini spec §3.4).
final class HarnessOutputGrokTests: XCTestCase {
    private func load(_ name: String, _ ext: String) throws -> Data {
        try Data(contentsOf: try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: ext, subdirectory: "Fixtures/Intake")))
    }

    func testParsesStructuredOutputAndSession() throws {
        let out = try HarnessOutput.parse(.grok, stdout: try load("grok-p-schema", "jsonl"))
        XCTAssertEqual(out.sessionID, "0199c1a2-4b7e-7000-8000-00000000a001")
        XCTAssertEqual(try JSONSerialization.jsonObject(with: out.structured) as? [String: String], ["answer": "PONG"])
    }

    /// The real signed-out run (grok 1.0.30): an `is_error` result whose reason is only in
    /// `errors[]`, and an EMPTY session id. It must surface that reason, not "no session".
    func testSignedOutRunReportsItsError() throws {
        XCTAssertThrowsError(try HarnessOutput.parse(.grok, stdout: try load("grok-auth-error", "jsonl"))) { error in
            guard case .isError(let text) = error as? HarnessOutput.ParseError else { return XCTFail("\(error)") }
            XCTAssertTrue(text.hasPrefix("Not signed in."), text)
        }
    }

    func testStructuredRetriesExhaustedIsAnError() {
        let stream = #"{"type":"system","subtype":"init","session_id":"S"}"# + "\n"
            + #"{"type":"result","subtype":"error_max_structured_output_retries","is_error":true,"errors":["structured output validation failed"],"session_id":"S"}"# + "\n"
        XCTAssertThrowsError(try HarnessOutput.parse(.grok, stdout: Data(stream.utf8))) {
            XCTAssertEqual($0 as? HarnessOutput.ParseError, .isError("structured output validation failed"))
        }
    }

    /// No `structured_output`: the result text must itself be JSON, else it's `notJSON`.
    func testFallsBackToResultTextAndRejectsProse() throws {
        let ok = #"{"type":"result","subtype":"success","is_error":false,"result":"{\"answer\":\"X\"}","session_id":"S"}"#
        XCTAssertEqual(try JSONSerialization.jsonObject(with: try HarnessOutput.parse(.grok, stdout: Data(ok.utf8)).structured)
                       as? [String: String], ["answer": "X"])
        let prose = #"{"type":"result","subtype":"success","is_error":false,"result":"Here you go","session_id":"S"}"#
        XCTAssertThrowsError(try HarnessOutput.parse(.grok, stdout: Data(prose.utf8))) {
            XCTAssertEqual($0 as? HarnessOutput.ParseError, .notJSON("Here you go"))
        }
    }

    /// A stream cut off before its `result` has no answer, whatever it said on the way.
    func testTruncatedStreamHasNoResult() {
        let stream = #"{"type":"system","subtype":"init","session_id":"S"}"# + "\n" + "garbage\n"
        XCTAssertThrowsError(try HarnessOutput.parse(.grok, stdout: Data(stream.utf8))) {
            XCTAssertEqual($0 as? HarnessOutput.ParseError, .noResult)
        }
        XCTAssertThrowsError(try HarnessOutput.parse(.grok, stdout: Data("garbage\n".utf8))) {
            XCTAssertEqual($0 as? HarnessOutput.ParseError, .noSession)
        }
    }

    /// The single-object `--output-format json` shape (`sessionId`, `text`), which
    /// `--json-schema` alone implies — parsed too, so a format change can't pause every round.
    func testAcceptsTheSingleObjectJSONShape() throws {
        let json = #"{"text":"{\"answer\":\"J\"}","stopReason":"end_turn","sessionId":"S2","num_turns":1}"#
        let out = try HarnessOutput.parse(.grok, stdout: Data(json.utf8))
        XCTAssertEqual(out.sessionID, "S2")
        XCTAssertEqual(try JSONSerialization.jsonObject(with: out.structured) as? [String: String], ["answer": "J"])
    }
}
