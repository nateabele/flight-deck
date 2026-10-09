import Foundation
import IntakeKit

/// OpenCode's per-agent settings: which model a new session runs on, and which of OpenCode's
/// own agents ("build", "plan", or a user-defined one) drives it.
///
/// Typed fields rather than a command line, for codex's reason: neither travels as a flag.
/// Both are sent in the `POST /session` body that creates the conversation, and OpenCode
/// stores them on the session row — so they follow the conversation across a resume without
/// Flight Deck having to re-send them, and a tab attached to an existing session keeps
/// whatever that session was created with.
///
/// `nil` means "OpenCode's own default", which is whatever `opencode.json` names. That is the
/// common case and deliberately the empty state: a user who configured OpenCode already has
/// a model, and an override here should only ever be a choice they made in Flight Deck.
struct OpenCodeOptions: Codable, Equatable, Sendable {
    /// `provider/model`, exactly as `opencode.json`'s own `"model"` key and `opencode -m`
    /// spell it — e.g. `ollama/qwen3-coder:32k`. The split happens at the FIRST slash only:
    /// Ollama model names carry their own (`hf.co/org/model:tag`), so splitting at the last
    /// one would send half the model name as the provider.
    var model: String?
    var agent: String?

    init(model: String? = nil, agent: String? = nil) {
        self.model = model
        self.agent = agent
    }

    /// `model` as the `{providerID, id}` pair `POST /session` takes, or nil when unset or when
    /// it names no provider. A bare model name is refused rather than guessed at: OpenCode
    /// rejects a session body whose model has no provider, and failing the whole creation
    /// over a cosmetic default is worse than letting OpenCode choose.
    var modelReference: (providerID: String, modelID: String)? {
        guard let model, let slash = model.firstIndex(of: "/") else { return nil }
        let provider = String(model[..<slash])
        let id = String(model[model.index(after: slash)...])
        guard !provider.isEmpty, !id.isEmpty else { return nil }
        return (provider, id)
    }

    var isEmpty: Bool { model == nil && agent == nil }

    static func merge(global: OpenCodeOptions, project: OpenCodeOptions) -> OpenCodeOptions {
        OpenCodeOptions(model: project.model ?? global.model, agent: project.agent ?? global.agent)
    }
}
