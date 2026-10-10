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

/// grok's half: `-m` and `--effort` on its command line, carried as `GrokOptions`.
enum GrokLaunchOverrides {
    static func apply(_ overrides: LaunchOverrides, to options: AgentOptions) -> RoutingCapability<AgentOptions> {
        guard case .grok(var grok) = options else { return .unsupported(reason: "grok was handed another agent's options") }
        if let model = overrides.model { grok.model = model }
        for (knob, value) in overrides.knobs.sorted(by: { $0.key < $1.key }) {
            switch knob {
            case "effort": grok.effort = value
            default: return .unsupported(reason: "grok has no knob \(knob)")
            }
        }
        return .supported(.grok(grok))
    }
}

/// The one way a routing capability may type into a tab: the store's own prompt gate, which
/// waits for a real composer and queues behind a running turn.
@MainActor
protocol SessionCommandSink: AnyObject {
    func submitCommand(_ text: String, to session: UUID) -> SessionStore.PromptDispatch
}

/// Capabilities are built by `RoutingCapabilityRegistry.standard()` with no arguments, so the
/// sink is attached afterwards rather than injected.
@MainActor
protocol CommandSinkAttachable: AnyObject {
    var commands: SessionCommandSink? { get set }
}

extension RoutingCapabilityRegistry {
    func attachCommandSink(_ sink: SessionCommandSink) {
        for agent in agents { (capabilities(for: agent) as? CommandSinkAttachable)?.commands = sink }
    }
}

/// A model override for an agy tab. Only a Gemini slug is taken: agy also serves Claude and
/// GPT-OSS models, and a gemini tab running one would be a gemini tab in name only. agy has no
/// knobs beyond the model (the slug carries the effort).
enum GeminiLaunchOverrides {
    static func apply(_ overrides: LaunchOverrides, to options: AgentOptions) -> RoutingCapability<AgentOptions> {
        guard case .gemini(var gemini) = options else { return .unsupported(reason: "gemini was handed another agent's options") }
        if let model = overrides.model {
            guard GeminiAdapter.isLaunchableModel(model) else {
                return .unsupported(reason: "\(model) is not a Gemini model agy can launch")
            }
            gemini.model = model
        }
        if let knob = overrides.knobs.keys.sorted().first {
            return .unsupported(reason: "gemini has no knob \(knob)")
        }
        return .supported(.gemini(gemini))
    }
}

/// OpenCode's half: the model is `OpenCodeOptions.model`, sent in the body that creates the
/// session. Only a `provider/model` id is taken — OpenCode refuses a session whose model names
/// no provider. No knobs (see `OpenCodeRoutingCapabilities.knobSchema`).
enum OpenCodeLaunchOverrides {
    static func apply(_ overrides: LaunchOverrides, to options: AgentOptions) -> RoutingCapability<AgentOptions> {
        guard case .opencode(var opencode) = options else { return .unsupported(reason: "opencode was handed another agent's options") }
        if let model = overrides.model {
            guard OpenCodeOptions(model: model).modelReference != nil else {
                return .unsupported(reason: "\(model) names no provider; OpenCode needs provider/model")
            }
            opencode.model = model
        }
        if let knob = overrides.knobs.keys.sorted().first {
            return .unsupported(reason: "opencode has no knob \(knob)")
        }
        return .supported(.opencode(opencode))
    }
}

enum ContextResetError: Error, Equatable { case refused(String) }

/// A context reset is a slash command typed into the agent's own composer: `/clear` for claude,
/// `/new` for codex (a new thread, which `CodexPinReconciler` follows).
@MainActor
enum ContextReset {
    static let claudeCommand = "/clear"
    static let codexCommand = "/new"
    static let geminiCommand = "/clear"

    static func typing(_ command: String, into session: Session, via sink: SessionCommandSink?) throws -> RoutingCapability<Void> {
        guard let sink else { return .unsupported(reason: "no command channel attached") }
        let dispatch = sink.submitCommand(command, to: session.id)
        if let code = dispatch.errorCode { throw ContextResetError.refused(code) }
        return .supported(())
    }
}
