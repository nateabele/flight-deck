import Foundation

/// The subset of codex's `thread/start` params Flight Deck exposes. Typed, not stringly:
/// codex takes these over JSON-RPC, so there is no command line to build or quote.
struct CodexThreadOptions: Codable, Equatable, Sendable {
    var model: String?
    var sandbox: String?
    var approvalPolicy: String?
    var addDirs: [String]

    init(model: String? = nil, sandbox: String? = nil, approvalPolicy: String? = nil, addDirs: [String] = []) {
        self.model = model
        self.sandbox = sandbox
        self.approvalPolicy = approvalPolicy
        self.addDirs = addDirs
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
    func asThreadStartParams(cwd: String) -> [String: Any] {
        var params: [String: Any] = ["cwd": cwd]
        if let model { params["model"] = model }
        if let sandbox { params["sandbox"] = sandbox }
        if let approvalPolicy { params["approvalPolicy"] = approvalPolicy }
        if !addDirs.isEmpty {
            params["addDirs"] = addDirs
            // `sandbox_workspace_write.writable_roots` is codex's own config key — see
            // `SandboxWorkspaceWrite` in the generated schema. Only sent when there is
            // something to say: an empty override is still an override, and would replace
            // whatever the user's `config.toml` set.
            params["config"] = ["sandbox_workspace_write": ["writable_roots": addDirs]]
        }
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
            addDirs: project.addDirs.isEmpty ? global.addDirs : project.addDirs
        )
    }
}
