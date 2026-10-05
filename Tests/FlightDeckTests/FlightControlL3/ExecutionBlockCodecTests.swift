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

    // Fix 1: flight_deck validation
    func testEncodeRefusesNonObjectFlightDeck() {
        let ctx = #"{"flight_deck":"not an object"}"#
        XCTAssertThrowsError(try ExecutionBlockCodec.encode(block(), into: ctx)) {
            XCTAssertEqual($0 as? ExecutionBlockError, .invalidField("flight_deck", "not an object"))
        }
    }

    func testDecodeRefusesNonObjectFlightDeck() {
        let ctx = #"{"flight_deck":"not an object","execution":{"v":1,"kind":"k","harness":"h","model":"m","pool":"p","source":{"by":"rule","reason":"r","at":"2026-10-04T18:00:00Z"}}}"#
        XCTAssertEqual(ExecutionBlockCodec.decode(agentContext: ctx), .failure(.invalidField("flight_deck", "not an object")))
    }

    func testDecodeAbsentFlightDeckStillReturnsNil() {
        let ctx = #"{"instructions":"something"}"#
        XCTAssertNil(try ExecutionBlockCodec.decode(agentContext: ctx).get())
    }

    // Fix 2: source.ruleId and host validation
    func testDecodeRejectsNonStringRuleId() {
        func ctx(_ exec: String) -> String { #"{"flight_deck":{"execution":"# + exec + "}}" }
        let src = #""source":{"by":"rule","reason":"r","at":"2026-10-04T18:00:00Z","ruleId":123}"#
        XCTAssertEqual(ExecutionBlockCodec.decode(agentContext: ctx(#"{"v":1,"kind":"k","harness":"h","model":"m","pool":"p","# + src + "}")),
                       .failure(.invalidField("source.ruleId", "not a string")))
    }

    func testDecodeRejectsNonStringHost() {
        func ctx(_ exec: String) -> String { #"{"flight_deck":{"execution":"# + exec + "}}" }
        let src = #""source":{"by":"rule","reason":"r","at":"2026-10-04T18:00:00Z"}"#
        XCTAssertEqual(ExecutionBlockCodec.decode(agentContext: ctx(#"{"v":1,"kind":"k","harness":"h","model":"m","pool":"p","# + src + #","host":123}"#)),
                       .failure(.invalidField("host", "not a string")))
    }

    // Fix 3: v validation (integer, >= 1)
    func testDecodeRejectsNonIntegerV() {
        func ctx(_ exec: String) -> String { #"{"flight_deck":{"execution":"# + exec + "}}" }
        let src = #""source":{"by":"rule","reason":"r","at":"2026-10-04T18:00:00Z"}"#
        XCTAssertEqual(ExecutionBlockCodec.decode(agentContext: ctx(#"{"v":"1","kind":"k","harness":"h","model":"m","pool":"p","# + src + "}")),
                       .failure(.invalidField("v", "not an integer")))
        XCTAssertEqual(ExecutionBlockCodec.decode(agentContext: ctx(#"{"v":1.5,"kind":"k","harness":"h","model":"m","pool":"p","# + src + "}")),
                       .failure(.invalidField("v", "not an integer")))
    }

    func testDecodeRejectsVLessThanOne() {
        func ctx(_ exec: String) -> String { #"{"flight_deck":{"execution":"# + exec + "}}" }
        let src = #""source":{"by":"rule","reason":"r","at":"2026-10-04T18:00:00Z"}"#
        XCTAssertEqual(ExecutionBlockCodec.decode(agentContext: ctx(#"{"v":0,"kind":"k","harness":"h","model":"m","pool":"p","# + src + "}")),
                       .failure(.invalidField("v", "must be at least 1")))
    }

    func testDecodeRejectsNonBooleanPinned() {
        func ctx(_ exec: String) -> String { #"{"flight_deck":{"execution":"# + exec + "}}" }
        let src = #""source":{"by":"rule","reason":"r","at":"2026-10-04T18:00:00Z"}"#
        // 1 and 0 should be rejected
        XCTAssertEqual(ExecutionBlockCodec.decode(agentContext: ctx(#"{"v":1,"kind":"k","harness":"h","model":"m","pool":"p","pinned":1,"# + src + "}")),
                       .failure(.invalidField("pinned", "not a boolean")))
        XCTAssertEqual(ExecutionBlockCodec.decode(agentContext: ctx(#"{"v":1,"kind":"k","harness":"h","model":"m","pool":"p","pinned":0,"# + src + "}")),
                       .failure(.invalidField("pinned", "not a boolean")))
        // true from JSON should decode fine
        let ctxWithTrue = ctx(#"{"v":1,"kind":"k","harness":"h","model":"m","pool":"p","pinned":true,"# + src + "}")
        XCTAssertNotNil(try ExecutionBlockCodec.decode(agentContext: ctxWithTrue).get())
    }

    func testDecodeVMissing() {
        func ctx(_ exec: String) -> String { #"{"flight_deck":{"execution":"# + exec + "}}" }
        let src = #""source":{"by":"rule","reason":"r","at":"2026-10-04T18:00:00Z"}"#
        XCTAssertEqual(ExecutionBlockCodec.decode(agentContext: ctx(#"{"kind":"k","harness":"h","model":"m","pool":"p","# + src + "}")),
                       .failure(.missingField("v")))
    }

    func testDecodeVBoolean() {
        func ctx(_ exec: String) -> String { #"{"flight_deck":{"execution":"# + exec + "}}" }
        let src = #""source":{"by":"rule","reason":"r","at":"2026-10-04T18:00:00Z"}"#
        XCTAssertEqual(ExecutionBlockCodec.decode(agentContext: ctx(#"{"v":true,"kind":"k","harness":"h","model":"m","pool":"p","# + src + "}")),
                       .failure(.invalidField("v", "not an integer")))
    }

    func testDecodeFlightDeckNull() {
        let ctx = #"{"flight_deck":null,"other":"data"}"#
        XCTAssertNil(try ExecutionBlockCodec.decode(agentContext: ctx).get())
    }

    func testEncodeIntoFlightDeckNull() {
        let ctx = #"{"flight_deck":null,"other":"data"}"#
        let json = try! ExecutionBlockCodec.encode(block(), into: ctx)
        let obj = try! JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
        XCTAssertNotNil(obj["flight_deck"])
        XCTAssertEqual(obj["other"] as? String, "data")
    }
}
