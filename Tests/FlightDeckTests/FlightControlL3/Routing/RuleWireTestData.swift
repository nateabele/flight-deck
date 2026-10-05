import Foundation
import IntakeKit

extension RoutingTestData {
    static let specSentence = "Use Codex for unit and integration tests, and for complex algorithms"

    /// What a compiler should answer for `specSentence`: spec L3-R §2's compiled form.
    static let specWire = RuleCompilerWire(
        ok: true, reason: nil, mode: "any",
        terms: [.init(dimension: "test-authoring", atLeast: 0.5, kind: nil),
                .init(dimension: "algorithmic-reasoning", atLeast: 0.6, kind: nil),
                .init(dimension: nil, atLeast: nil, kind: "tests")],
        harness: "codex", model: "gpt-6-sol", modelDefaulted: false,
        knobs: [.init(name: "effort", value: "high")], pool: "codex-subs", fallbackPool: nil)

    static func input(_ sentence: String = RoutingTestData.specSentence,
                      catalogs: AdapterCatalogs = RoutingTestData.catalogs) -> RuleCompilerInput {
        RuleCompilerInput(sentence: sentence, kinds: kinds, catalogs: catalogs, pools: pools, defaultPools: defaultPools)
    }
}
