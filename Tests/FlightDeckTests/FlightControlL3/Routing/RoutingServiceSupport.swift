import Foundation
import IntakeKit
@testable import FlightDeck

/// A compiler that answers from a script and records what it was asked.
final class ScriptedCompiler: RuleCompiling, @unchecked Sendable {
    var proposal: RuleProposal
    /// Runs on the main actor just before the answer — lets a test edit a rule mid-compile.
    var beforeReturning: (@MainActor () -> Void)?
    private(set) var inputs: [RuleCompilerInput] = []
    let ref = CompilerRef(harness: "claude", model: "haiku")
    init(_ proposal: RuleProposal) { self.proposal = proposal }
    func propose(_ input: RuleCompilerInput) async -> RuleProposal {
        inputs.append(input)
        if let hook = beforeReturning { await MainActor.run { hook() } }
        return proposal
    }
}

final class FakeOpenTasks: OpenTaskReading, @unchecked Sendable {
    var result: Result<[TaskContextRow], OpenTaskReadError> = .success([])
    func openTasks(project: String) async -> Result<[TaskContextRow], OpenTaskReadError> { result }
}

final class RecordingBlockWriter: BlockWriting, @unchecked Sendable {
    private(set) var writes: [(id: String, block: ExecutionBlock, project: String)] = []
    var outcome: BlockWriteOutcome = .written
    /// Per-task answers, for a test that needs one write to fail or lose a race.
    var outcomes: [String: BlockWriteOutcome] = [:]
    func writeBlock(_ block: ExecutionBlock, id: String, project: String) async -> BlockWriteOutcome {
        writes.append((id, block, project))
        return outcomes[id] ?? outcome
    }
}

struct FixedHints: RuleHintSource {
    var fixed: RuleHint?
    func hint(for rule: RoutingRule, kinds: [TaskKind], catalogs: AdapterCatalogs) -> RuleHint? {
        rule.id == fixed?.ruleID ? fixed : nil
    }
}

@MainActor
enum RoutingServiceSupport {
    /// The spec wire with no pool named, so it compiles to the agent's default pool — the only
    /// pools `DefaultPoolDirectory` has.
    static var serviceWire: RuleCompilerWire {
        var w = RoutingTestData.specWire
        w.pool = nil
        return w
    }

    static func make(prefs: PreferencesStore? = nil, compiler: ScriptedCompiler? = nil,
                     hints: any RuleHintSource = NoRuleHints(), tasks: FakeOpenTasks? = nil,
                     writer: RecordingBlockWriter? = nil,
                     loadCatalogs: (@MainActor () async -> AdapterCatalogs)? = nil) -> RoutingService {
        let compiler = compiler ?? ScriptedCompiler(.wire(serviceWire))
        var next = 0
        return RoutingService(preferences: prefs ?? PreferencesStore(persistence: nil),
                              kindStore: KindRegistryStore(now: { RoutingTestData.at }),
                              makeCompiler: { compiler },
                              loadCatalogs: loadCatalogs ?? { RoutingTestData.catalogs },
                              pools: DefaultPoolDirectory(harnesses: ["codex", "claude"]),
                              hints: hints, tasks: tasks ?? FakeOpenTasks(), writer: writer ?? RecordingBlockWriter(),
                              makeRuleID: { next += 1; return "r\(next)" }, now: { RoutingTestData.at })
    }
}
