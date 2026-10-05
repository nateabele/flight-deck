import XCTest
import IntakeKit

/// The execution block is the one shape every Level 3 branch reads and writes, and it lives
/// inside br's `agent_context`, a field other tools also write. These tests pin the two promises
/// the rest of Level 3 leans on: a block round-trips exactly, and writing one never destroys
/// anything else stored in `agent_context`.
final class ExecutionBlockCodecTests: XCTestCase {
    private let at = Date(timeIntervalSince1970: 1_790_000_000)

    private func block(pinned: Bool = false) -> ExecutionBlock {
        ExecutionBlock(kind: "snapshot-tests", harness: "codex", model: "gpt-6-sol",
                       knobs: ["effort": "high"], pool: "codex-subs",
                       source: AssignmentSource(by: .rule, ruleId: "r3",
                                                reason: "test-authoring 0.8 → codex", at: at),
                       pinned: pinned)
    }

    func testRoundTripsEveryField() throws {
        let json = try ExecutionBlockCodec.encode(block(pinned: true), into: nil)
        XCTAssertEqual(try ExecutionBlockCodec.decode(agentContext: json).get(), block(pinned: true))
    }

    func testNilOrAbsentBlockDecodesToNil() throws {
        XCTAssertNil(try ExecutionBlockCodec.decode(agentContext: nil).get())
        XCTAssertNil(try ExecutionBlockCodec.decode(agentContext: "").get())
        XCTAssertNil(try ExecutionBlockCodec.decode(agentContext: #"{"instructions":"x"}"#).get())
        XCTAssertNil(try ExecutionBlockCodec.decode(agentContext: #"{"flight_deck":{}}"#).get())
    }

    func testEncodePreservesForeignTopLevelKeys() throws {
        let json = try ExecutionBlockCodec.encode(block(), into: #"{"instructions":"keep me","n":3}"#)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual(obj["instructions"] as? String, "keep me")
        XCTAssertEqual(obj["n"] as? Int, 3)
    }

    func testEncodePreservesSiblingFlightDeckKeys() throws {
        let json = try ExecutionBlockCodec.encode(block(), into: #"{"flight_deck":{"notes":"keep"}}"#)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let fd = try XCTUnwrap(obj["flight_deck"] as? [String: Any])
        XCTAssertEqual(fd["notes"] as? String, "keep")
        XCTAssertNotNil(fd["execution"])
    }

    func testEncodeReplacesAnExistingBlock() throws {
        let first = try ExecutionBlockCodec.encode(block(), into: nil)
        var changed = block(); changed.model = "gpt-6-terra"
        let second = try ExecutionBlockCodec.encode(changed, into: first)
        XCTAssertEqual(try ExecutionBlockCodec.decode(agentContext: second).get()?.model, "gpt-6-terra")
    }

    func testEncodeRefusesNonObjectContext() {
        XCTAssertThrowsError(try ExecutionBlockCodec.encode(block(), into: #""a bare string""#)) {
            XCTAssertEqual($0 as? ExecutionBlockError, .notJSONObject)
        }
        XCTAssertThrowsError(try ExecutionBlockCodec.encode(block(), into: "not json")) {
            XCTAssertEqual($0 as? ExecutionBlockError, .notJSONObject)
        }
    }

    func testDecodeRejectsNewerVersion() {
        let ctx = #"{"flight_deck":{"execution":{"v":2,"kind":"k","harness":"h","model":"m","pool":"p","source":{"by":"rule","reason":"r","at":"2026-10-04T18:00:00Z"}}}}"#
        XCTAssertEqual(ExecutionBlockCodec.decode(agentContext: ctx), .failure(.unsupportedVersion(2)))
    }

    func testDecodeNamesEachMissingOrInvalidField() {
        func ctx(_ exec: String) -> String { #"{"flight_deck":{"execution":"# + exec + "}}" }
        let src = #""source":{"by":"rule","reason":"r","at":"2026-10-04T18:00:00Z"}"#
        XCTAssertEqual(ExecutionBlockCodec.decode(agentContext: ctx(#"{"kind":"k"}"#)), .failure(.missingField("v")))
        XCTAssertEqual(ExecutionBlockCodec.decode(agentContext: ctx(#"{"v":1,"harness":"h","model":"m","pool":"p","# + src + "}")),
                       .failure(.missingField("kind")))
        XCTAssertEqual(ExecutionBlockCodec.decode(agentContext: ctx(#"{"v":1,"kind":"","harness":"h","model":"m","pool":"p","# + src + "}")),
                       .failure(.invalidField("kind", "empty")))
        XCTAssertEqual(ExecutionBlockCodec.decode(agentContext: ctx(#"{"v":1,"kind":"k","harness":"h","model":"m","pool":"p","knobs":{"effort":3},"# + src + "}")),
                       .failure(.invalidField("knobs", "values must be strings")))
        XCTAssertEqual(ExecutionBlockCodec.decode(agentContext: ctx(#"{"v":1,"kind":"k","harness":"h","model":"m","pool":"p","source":{"by":"vibes","reason":"r","at":"2026-10-04T18:00:00Z"}}"#)),
                       .failure(.invalidField("source.by", "unknown value vibes")))
        XCTAssertEqual(ExecutionBlockCodec.decode(agentContext: ctx(#""oops""#)),
                       .failure(.invalidField("execution", "not an object")))
    }

    func testPinnedAndHostDefault() throws {
        let ctx = #"{"flight_deck":{"execution":{"v":1,"kind":"k","harness":"h","model":"m","pool":"p","source":{"by":"manual","reason":"r","at":"2026-10-04T18:00:00Z"}}}}"#
        let b = try XCTUnwrap(ExecutionBlockCodec.decode(agentContext: ctx).get())
        XCTAssertFalse(b.pinned); XCTAssertNil(b.host); XCTAssertEqual(b.knobs, [:])
        XCTAssertEqual(b.modelRef, ModelRef(harness: "h", model: "m", knobs: [:]))
    }
}
