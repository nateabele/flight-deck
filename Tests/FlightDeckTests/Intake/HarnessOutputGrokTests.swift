import XCTest
import IntakeKit

/// `HeadlessOutput.parse(.grok, …)` over grok's `streaming-messages-json` (grok/gemini spec §3.4).
final class HarnessOutputGrokTests: XCTestCase {
    private func load(_ name: String, _ ext: String) throws -> Data {
        try Data(contentsOf: try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: ext, subdirectory: "Fixtures/Intake")))
    }

    /// Live captures (grok 1.0.30, grok-4.7, 2026-10-07, synthetic one-file project): a fresh
    /// read-only run with the REAL strict triage schema, then `--resume <its id>` with the
    /// strict review schema, asked for a number the first run was told. Both strict schemas
    /// were accepted as-is — no transformation needed — and `structured_output` carries the
    /// answer. The resume keeps the session id and remembers.
    func testParsesTheLiveFreshAndResumedRuns() throws {
        let fresh = try HeadlessOutput.parse(.grok, stdout: try load("grok-p-schema", "jsonl"))
        XCTAssertEqual(fresh.sessionID, "20c36533-a9a3-427b-81a2-51ed2484802d")
        let triage = try XCTUnwrap(try JSONSerialization.jsonObject(with: fresh.structured) as? [String: Any])
        XCTAssertEqual(triage["kind"] as? String, "questions")
        XCTAssertEqual((triage["questions"] as? [String])?.count, 1)
        XCTAssertTrue(triage["changeSet"] is NSNull)
        let resumed = try HeadlessOutput.parse(.grok, stdout: try load("grok-p-schema-resume", "jsonl"))
        XCTAssertEqual(resumed.sessionID, fresh.sessionID)
        let review = try XCTUnwrap(try JSONSerialization.jsonObject(with: resumed.structured) as? [String: Any])
        XCTAssertEqual(review["summary"] as? String, "4817")
    }

    /// Live: an unknown `-m` fails loudly (exit 1) — no silent fallback to the default model.
    func testBadModelIsAnError() throws {
        XCTAssertThrowsError(try HeadlessOutput.parse(.grok, stdout: try load("grok-bad-model", "jsonl"))) { error in
            guard case .isError(let text) = error as? HeadlessOutput.ParseError else { return XCTFail("\(error)") }
            XCTAssertTrue(text.contains("unknown model id"), text)
        }
    }

    /// The real signed-out run (grok 1.0.30): an `is_error` result whose reason is only in
    /// `errors[]`, and an EMPTY session id. It must surface that reason, not "no session".
    func testSignedOutRunReportsItsError() throws {
        XCTAssertThrowsError(try HeadlessOutput.parse(.grok, stdout: try load("grok-auth-error", "jsonl"))) { error in
            guard case .isError(let text) = error as? HeadlessOutput.ParseError else { return XCTFail("\(error)") }
            XCTAssertTrue(text.hasPrefix("Not signed in."), text)
        }
    }

    func testStructuredRetriesExhaustedIsAnError() {
        let stream = #"{"type":"system","subtype":"init","session_id":"S"}"# + "\n"
            + #"{"type":"result","subtype":"error_max_structured_output_retries","is_error":true,"errors":["structured output validation failed"],"session_id":"S"}"# + "\n"
        XCTAssertThrowsError(try HeadlessOutput.parse(.grok, stdout: Data(stream.utf8))) {
            XCTAssertEqual($0 as? HeadlessOutput.ParseError, .isError("structured output validation failed"))
        }
    }

    /// No `structured_output`: the result text must itself be JSON, else it's `notJSON`.
    func testFallsBackToResultTextAndRejectsProse() throws {
        let ok = #"{"type":"result","subtype":"success","is_error":false,"result":"{\"answer\":\"X\"}","session_id":"S"}"#
        XCTAssertEqual(try JSONSerialization.jsonObject(with: try HeadlessOutput.parse(.grok, stdout: Data(ok.utf8)).structured)
                       as? [String: String], ["answer": "X"])
        let prose = #"{"type":"result","subtype":"success","is_error":false,"result":"Here you go","session_id":"S"}"#
        XCTAssertThrowsError(try HeadlessOutput.parse(.grok, stdout: Data(prose.utf8))) {
            XCTAssertEqual($0 as? HeadlessOutput.ParseError, .notJSON("Here you go"))
        }
    }

    /// A stream cut off before its `result` has no answer, whatever it said on the way.
    func testTruncatedStreamHasNoResult() {
        let stream = #"{"type":"system","subtype":"init","session_id":"S"}"# + "\n" + "garbage\n"
        XCTAssertThrowsError(try HeadlessOutput.parse(.grok, stdout: Data(stream.utf8))) {
            XCTAssertEqual($0 as? HeadlessOutput.ParseError, .noResult)
        }
        XCTAssertThrowsError(try HeadlessOutput.parse(.grok, stdout: Data("garbage\n".utf8))) {
            XCTAssertEqual($0 as? HeadlessOutput.ParseError, .noSession)
        }
    }

    /// The single-object `--output-format json` shape (`sessionId`, `text`), which
    /// `--json-schema` alone implies — parsed too, so a format change can't pause every round.
    func testAcceptsTheSingleObjectJSONShape() throws {
        let json = #"{"text":"{\"answer\":\"J\"}","stopReason":"end_turn","sessionId":"S2","num_turns":1}"#
        let out = try HeadlessOutput.parse(.grok, stdout: Data(json.utf8))
        XCTAssertEqual(out.sessionID, "S2")
        XCTAssertEqual(try JSONSerialization.jsonObject(with: out.structured) as? [String: String], ["answer": "J"])
    }
}
