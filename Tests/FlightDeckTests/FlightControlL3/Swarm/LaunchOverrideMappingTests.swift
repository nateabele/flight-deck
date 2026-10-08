import XCTest
import IntakeKit
@testable import FlightDeck

/// A block's model and knobs reach a launch only through the agent's own capability, so these pin
/// the one translation each agent does — claude to command-line flags, codex to thread params — and
/// that a knob an agent does not have is refused, never dropped: a task routed to "effort=max" that
/// launched at the default would be the silent wrong-model failure routing exists to prevent.
@MainActor
final class LaunchOverrideMappingTests: XCTestCase {
    func testClaudeModelAndEffortBecomeFlags() throws {
        let result = ClaudeLaunchOverrides.apply(LaunchOverrides(model: "opus", knobs: ["effort": "high"]),
                                                 to: .claude(FlagSet(values: ["--verbose": .on])))
        guard case .supported(.claude(let flags)) = result else { return XCTFail("expected claude flags") }
        XCTAssertEqual(flags.values["--model"], .value("opus"))
        XCTAssertEqual(flags.values["--effort"], .value("high"))
        XCTAssertEqual(flags.values["--verbose"], .on, "preferences under the override survive")
    }

    func testClaudeRefusesAnUnknownKnob() {
        guard case .unsupported(let reason) = ClaudeLaunchOverrides.apply(
            LaunchOverrides(model: nil, knobs: ["agent": "build"]), to: .claude(FlagSet())) else {
            return XCTFail("an unknown knob must be refused")
        }
        XCTAssertTrue(reason.contains("agent"))
    }

    func testCodexModelAndEffortBecomeThreadOptions() {
        let result = CodexLaunchOverrides.apply(LaunchOverrides(model: "gpt-6-sol", knobs: ["effort": "high"]),
                                                to: .codex(CodexThreadOptions(sandbox: "read-only")))
        guard case .supported(.codex(let options)) = result else { return XCTFail("expected codex options") }
        XCTAssertEqual(options.model, "gpt-6-sol")
        XCTAssertEqual(options.reasoningEffort, "high")
        XCTAssertEqual(options.sandbox, "read-only")
    }

    func testCodexEffortTravelsAsConfig() {
        let params = CodexThreadOptions(model: "m", addDirs: ["/x"], reasoningEffort: "high")
            .asThreadStartParams(cwd: "/p", historyMode: nil)
        let config = params["config"] as? [String: Any]
        XCTAssertEqual(config?["model_reasoning_effort"] as? String, "high")
        XCTAssertNotNil(config?["sandbox_workspace_write"], "the addDirs override still rides along")
        XCTAssertNil(CodexThreadOptions(model: "m").asThreadStartParams(cwd: "/p", historyMode: nil)["config"],
                     "no override means no config key — an empty one would replace config.toml's")
    }

    func testWrongOptionsShapeIsRefused() {
        guard case .unsupported = ClaudeLaunchOverrides.apply(LaunchOverrides(model: "x", knobs: [:]),
                                                              to: .codex(CodexThreadOptions())) else {
            return XCTFail("claude must not accept codex options")
        }
    }

    func testStandardRegistryNowSupportsOverridesForBothAgents() {
        let registry = RoutingCapabilityRegistry.standard()
        for id in AgentID.tabReadyCases {
            let base = AgentOptions.empty(for: id)
            guard case .supported = registry.capabilities(for: id)!
                .applying(LaunchOverrides(model: "m", knobs: [:]), to: base) else {
                return XCTFail("\(id) should map a model override")
            }
        }
    }
}
