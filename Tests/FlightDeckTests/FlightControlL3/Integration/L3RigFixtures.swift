import Foundation
import IntakeKit
@testable import FlightDeck

extension L3IntegrationRig {
    /// The rule `SwarmEndToEndTests` routes by: unit and integration tests go to Codex.
    static let testsToCodexRule = RoutingRule(
        id: "r-tests", sentence: "Use Codex for unit and integration tests",
        compiled: CompiledRule(match: .any([.dimension("test-authoring", atLeast: 0.5)]),
                               assign: RuleAssign(agent: .codex, model: "gpt-6-sol",
                                                  knobs: ["effort": "high"], pool: "codex-default")),
        state: .confirmed)

    /// Two codex accounts, one ready task (`fx-valid`), the tests-to-codex rule confirmed.
    static func standard() throws -> L3IntegrationRig {
        try make(accounts: ["Work", "Personal"], agent: .codex, rule: testsToCodexRule, readyTasks: ["fx-valid"])
    }

    /// Launches one agent on Work, then pushes Work over hard with the agent idle, and ticks:
    /// the hand-off runs inside that tick. Returns the first agent's spawn.
    func launchAndCrossHard() async throws -> Spawn {
        feed(account: "Work", utilization: 0.30)
        feed(account: "Personal", utilization: 0.10)
        try await launch(cap: 1)
        await tick()
        let first = try XCTUnwrapRig(spawns.first)
        feed(account: "Work", utilization: 0.97)
        markIdle(first.session)
        await tick()
        return first
    }
}
