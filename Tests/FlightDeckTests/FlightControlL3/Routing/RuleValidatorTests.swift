import XCTest
import IntakeKit

/// The validator is the only thing standing between a model's answer and a confirmable rule
/// (spec L3-R §3). Every check is named, and only the first failure is reported.
final class RuleValidatorTests: XCTestCase {
    private typealias D = RoutingTestData

    private func validate(_ input: RuleCompilerInput = RoutingTestData.input(),
                          _ change: (inout RuleCompilerWire) -> Void) -> Result<CompiledRule, RuleValidationError> {
        var w = D.specWire
        change(&w)
        return RuleValidator.validate(w, input: input)
    }

    func testTheSpecRuleValidates() {
        XCTAssertEqual(validate { _ in }, .success(D.r3().compiled!))
    }

    func testANamelessModelTakesTheAgentsDefaultAndSaysSo() throws {
        let c = try validate { $0.model = nil }.get()
        XCTAssertEqual(c.assign.model, "gpt-6-sol")
        XCTAssertTrue(c.assign.modelDefaulted)
    }

    func testANamelessPoolTakesTheAgentsDefaultPool() throws {
        XCTAssertEqual(try validate { $0.pool = nil }.get().assign.pool, "codex-default")
    }

    func testAllModeCompilesToAll() throws {
        let compiled = try validate { $0.mode = "all" }.get()
        guard case .all(let terms) = compiled.match else { return XCTFail("\(compiled.match)") }
        XCTAssertEqual(terms.count, 3)
    }

    func testEveryInvalidInputIsNamed() {
        let cases: [(String, (inout RuleCompilerWire) -> Void, RuleValidationError)] = [
            ("dimension", { $0.terms[0].dimension = "teleportation" }, .unknownDimension("teleportation")),
            ("threshold", { $0.terms[0].atLeast = 1.5 }, .thresholdOutOfRange("test-authoring")),
            ("no threshold", { $0.terms[0].atLeast = nil }, .thresholdOutOfRange("test-authoring")),
            ("kind", { $0.terms[2].kind = "astrology" }, .unknownKind("astrology")),
            ("both in one term", { $0.terms[2].dimension = "debugging" }, .malformedTerm),
            ("no terms", { $0.terms = [] }, .emptyMatch),
            ("mode", { $0.mode = "some" }, .unknownMode("some")),
            ("no agent", { $0.harness = nil }, .missingHarness),
            ("agent", { $0.harness = "gemini" }, .unknownHarness("gemini")),
            ("model", { $0.model = "gpt-9" }, .unknownModel("codex", "gpt-9")),
            ("knob value", { $0.knobs = [.init(name: "effort", value: "max")] }, .knobRejected("codex", "gpt-6-sol", "effort", "max")),
            ("knob name", { $0.knobs = [.init(name: "agent", value: "build")] }, .knobRejected("codex", "gpt-6-sol", "agent", "build")),
            ("pool", { $0.pool = "nowhere" }, .unknownPool("nowhere")),
            ("pool owner", { $0.pool = "claude-subs" }, .poolBelongsElsewhere("claude-subs", owner: "claude", harness: "codex")),
            ("fallback pool", { $0.fallbackPool = "nowhere" }, .unknownPool("nowhere")),
            ("fallback is the pool", { $0.fallbackPool = "codex-subs" }, .fallbackIsPrimary("codex-subs")),
            ("declined", { $0.ok = false; $0.reason = "that is not a routing rule" }, .declined("that is not a routing rule")),
        ]
        for (name, change, expected) in cases {
            XCTAssertEqual(validate(D.input(), change), .failure(expected), name)
        }
    }

    func testADisabledAgentIsNamed() {
        let input = D.input(catalogs: D.catalogsDisabling(["codex"]))
        XCTAssertEqual(validate(input) { _ in }, .failure(.harnessDisabled("codex")))
    }

    func testTheFirstErrorWins() {
        XCTAssertEqual(validate { $0.terms[0].dimension = "teleportation"; $0.harness = "gemini" },
                       .failure(.unknownDimension("teleportation")))
    }

    func testADeclinedSentenceWithoutAReasonGetsOne() {
        XCTAssertEqual(validate { $0.ok = false; $0.reason = nil },
                       .failure(.declined("the compiler could not read this sentence as a rule")))
    }

    func testMessagesReadAsSentences() {
        XCTAssertEqual(RuleValidationError.unknownDimension("teleportation").message, "unknown dimension teleportation")
        XCTAssertEqual(RuleValidationError.poolBelongsElsewhere("claude-subs", owner: "claude", harness: "codex").message,
                       "pool claude-subs belongs to claude, not codex")
        XCTAssertEqual(RuleValidationError.unknownModel("codex", "gpt-9").message, "gpt-9 is not in codex's model list")
    }
}
