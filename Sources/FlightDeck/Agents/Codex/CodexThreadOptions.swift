import Foundation

/// The subset of codex's `thread/start` params Flight Deck exposes. Typed, not stringly:
/// codex takes these over JSON-RPC, so there is no command line to build or quote.
struct CodexThreadOptions: Codable, Equatable, Sendable {
    var model: String?
    var sandbox: String?
    var approvalPolicy: String?
    var addDirs: [String]
    /// A swarm task's `effort` knob (L3-S). Sent as codex's own `model_reasoning_effort` config
    /// key, never a param of ours; nil sends nothing, so `config.toml` keeps deciding.
    var reasoningEffort: String?

    init(model: String? = nil, sandbox: String? = nil, approvalPolicy: String? = nil, addDirs: [String] = [],
         reasoningEffort: String? = nil) {
        self.model = model
        self.sandbox = sandbox
        self.approvalPolicy = approvalPolicy
        self.addDirs = addDirs
        self.reasoningEffort = reasoningEffort
    }

    /// Typed params, not a command line. Omitted keys mean "codex's own default" — sending
    /// an explicit null would pin the value and defeat the user's `config.toml`.
    ///
    /// `model`, `sandbox` and `approvalPolicy` are real `ThreadStartParams` fields.
    /// **`addDirs` is not** — it appears nowhere in the schema `codex app-server
    /// generate-json-schema` emits at codex-cli 0.147.0, and probing a live app-server
    /// confirms it: `thread/start` accepts the key and ignores it, because serde drops
    /// unknown fields rather than rejecting them. It is still sent, unchanged, so nothing
    /// that reads these params regresses; the directories reach codex through `config`
    /// below, which is the same free-form override mechanism `codex -c` uses.
    ///
    /// `historyMode` is the one deliberate exception to "omitted means codex's own default":
    /// `CodexAdapter.prepare` and this app's rollout parser both require `legacy`, so a caller
    /// that has one to give pins it rather than inheriting whatever codex-cli 0.151.0+
    /// defaults to now. See `CodexAdapter.historyMode` for where the value comes from.
    func asThreadStartParams(cwd: String, historyMode: String?) -> [String: Any] {
        var params: [String: Any] = ["cwd": cwd]
        if let model { params["model"] = model }
        if let sandbox { params["sandbox"] = sandbox }
        if let approvalPolicy { params["approvalPolicy"] = approvalPolicy }
        if let historyMode { params["historyMode"] = historyMode }
        var config: [String: Any] = [:]
        if !addDirs.isEmpty {
            params["addDirs"] = addDirs
            // `sandbox_workspace_write.writable_roots` is codex's own config key — see
            // `SandboxWorkspaceWrite` in the generated schema. Only sent when there is
            // something to say: an empty override is still an override, and would replace
            // whatever the user's `config.toml` set.
            config["sandbox_workspace_write"] = ["writable_roots": addDirs]
        }
        if let reasoningEffort { config["model_reasoning_effort"] = reasoningEffort }
        if !config.isEmpty { params["config"] = config }
        return params
    }
}

extension CodexThreadOptions {
    /// Codex's counterpart to `FlagSetMerge.merge`. A nil project field inherits; a set field
    /// overrides. `addDirs` has no nil to test, so emptiness stands in for it — an empty
    /// project list inherits rather than clearing the global one, because "I set no extra
    /// directories here" is the overwhelmingly common state and must not erase a global.
    static func merge(global: CodexThreadOptions, project: CodexThreadOptions) -> CodexThreadOptions {
        CodexThreadOptions(
            model: project.model ?? global.model,
            sandbox: project.sandbox ?? global.sandbox,
            approvalPolicy: project.approvalPolicy ?? global.approvalPolicy,
            addDirs: project.addDirs.isEmpty ? global.addDirs : project.addDirs,
            reasoningEffort: project.reasoningEffort ?? global.reasoningEffort
        )
    }
}
