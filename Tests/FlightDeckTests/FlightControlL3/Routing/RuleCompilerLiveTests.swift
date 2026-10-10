import XCTest
import IntakeKit
@testable import FlightDeck

/// The fixture in `RuleCompilerTests` is only as good as its claim to look like real output.
/// This spends one haiku call to prove the real CLI accepts the schema and that the spec's
/// sentence compiles to a rule that routes tests to codex. Skipped unless `ROUTING_LIVE=1`.
final class RuleCompilerLiveTests: XCTestCase {
    func testHaikuCompilesTheSpecSentence() async throws {
        guard ProcessInfo.processInfo.environment["ROUTING_LIVE"] == "1" else {
            throw XCTSkip("set ROUTING_LIVE=1 — this spends tokens")
        }
        // Under $HOME, never /tmp (see BeadWriterLiveTests).
        let work = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".fd-routing-live-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let compiler = RuleCompiler(runner: SystemCommandRunner(), settings: .default, workDirectory: work,
                                    baseEnvironment: { LoginShellPath.repairing(ProcessInfo.processInfo.environment) })
        let input = RoutingTestData.input()
        let proposal = await compiler.propose(input)
        let outcome = RuleCompilation.finish(proposal, input: input)
        guard case .compiled(let rule) = outcome else { return XCTFail("\(outcome) — proposal: \(proposal)") }
        XCTAssertEqual(rule.assign.agent, .codex)
        XCTAssertTrue(rule.match.terms.contains { term in
            if case .dimension("test-authoring", _) = term { return true }
            return false
        }, "\(rule.match)")
    }
}
