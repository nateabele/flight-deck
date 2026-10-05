import Foundation
import IntakeKit

/// Claude's half of `AgentRoutingCapabilities.applying`: a model and knobs become command-line
/// flags laid over the project's resolved `FlagSet`. Only `effort` is a claude knob today
/// (`ClaudeFlagCatalog`'s `--effort`); any other knob is refused rather than dropped.
enum ClaudeLaunchOverrides {
    static func apply(_ overrides: LaunchOverrides, to options: AgentOptions) -> RoutingCapability<AgentOptions> {
        guard case .claude(var flags) = options else { return .unsupported(reason: "claude was handed codex options") }
        if let model = overrides.model { flags.values["--model"] = .value(model) }
        for (knob, value) in overrides.knobs.sorted(by: { $0.key < $1.key }) {
            switch knob {
            case "effort": flags.values["--effort"] = .value(value)
            default: return .unsupported(reason: "claude has no knob \(knob)")
            }
        }
        return .supported(.claude(flags))
    }
}

/// Codex's half: typed `thread/start` params. `effort` becomes `reasoningEffort`, which
/// `CodexThreadOptions.asThreadStartParams` sends as codex's own `model_reasoning_effort` key.
enum CodexLaunchOverrides {
    static func apply(_ overrides: LaunchOverrides, to options: AgentOptions) -> RoutingCapability<AgentOptions> {
        guard case .codex(var thread) = options else { return .unsupported(reason: "codex was handed claude options") }
        if let model = overrides.model { thread.model = model }
        for (knob, value) in overrides.knobs.sorted(by: { $0.key < $1.key }) {
            switch knob {
            case "effort": thread.reasoningEffort = value
            default: return .unsupported(reason: "codex has no knob \(knob)")
            }
        }
        return .supported(.codex(thread))
    }
}
