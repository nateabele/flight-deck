import Foundation

/// Session defaults shared by thread creation and the interactive resume command.
/// Both paths must carry overrides: the TUI loads its own configuration on resume.
struct CodexThreadOptions: Codable, Equatable, Sendable {
    var model: String?
    var sandbox: String?
    var approvalPolicy: String?
    var addDirs: [String]
    /// A swarm task's `effort` knob (L3-S). Sent as codex's own `model_reasoning_effort` config
    /// key, never a param of ours; nil sends nothing, so `config.toml` keeps deciding.
    var reasoningEffort: String?

    var reasoningSummary: String?
    var verbosity: String?
    var webSearch: String?
    var networkAccess: Bool?
    var developerInstructions: String?
    var modelInstructionsFile: String?

    init(model: String? = nil, sandbox: String? = nil, approvalPolicy: String? = nil, addDirs: [String] = [],
         reasoningEffort: String? = nil, reasoningSummary: String? = nil,
         verbosity: String? = nil, webSearch: String? = nil, networkAccess: Bool? = nil,
         developerInstructions: String? = nil, modelInstructionsFile: String? = nil) {
        self.model = model
        self.sandbox = sandbox
        self.approvalPolicy = approvalPolicy
        self.addDirs = addDirs
        self.reasoningEffort = reasoningEffort
        self.reasoningSummary = reasoningSummary
        self.verbosity = verbosity
        self.webSearch = webSearch
        self.networkAccess = networkAccess
        self.developerInstructions = developerInstructions
        self.modelInstructionsFile = modelInstructionsFile
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
        if !addDirs.isEmpty { params["addDirs"] = addDirs }
        let config = configOverrides
        if !config.isEmpty { params["config"] = config }
        return params
    }

    var configOverrides: [String: Any] {
        var config: [String: Any] = [:]
        var workspace: [String: Any] = [:]
        if !addDirs.isEmpty { workspace["writable_roots"] = addDirs }
        if let networkAccess { workspace["network_access"] = networkAccess }
        if !workspace.isEmpty { config["sandbox_workspace_write"] = workspace }
        if let reasoningEffort { config["model_reasoning_effort"] = reasoningEffort }
        if let reasoningSummary { config["model_reasoning_summary"] = reasoningSummary }
        if let verbosity { config["model_verbosity"] = verbosity }
        if let webSearch { config["web_search"] = webSearch }
        if let developerInstructions { config["developer_instructions"] = developerInstructions }
        if let modelInstructionsFile { config["model_instructions_file"] = modelInstructionsFile }
        return config
    }

    /// Each value is encoded as a TOML-compatible JSON literal, then shell quoted as one
    /// argument. Prompt text must never become shell syntax or an unquoted TOML value.
    var launchArguments: [String] {
        func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'" }
        func literal(_ value: Any) -> String {
            let data = try! JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys, .withoutEscapingSlashes])
            return String(decoding: data, as: UTF8.self)
        }
        var args: [String] = []
        if let model { args += ["--model", quote(model)] }
        if let sandbox { args += ["--sandbox", quote(sandbox)] }
        if let approvalPolicy { args += ["--config", quote("approval_policy=" + literal(approvalPolicy))] }
        // Dotted keys preserve other workspace settings from the account's config.toml.
        for key in configOverrides.keys.sorted() {
            let value = configOverrides[key]!
            if let nested = value as? [String: Any] {
                for child in nested.keys.sorted() {
                    args += ["--config", quote(key + "." + child + "=" + literal(nested[child]!))]
                }
            } else {
                args += ["--config", quote(key + "=" + literal(value))]
            }
        }
        return args
    }

    /// These options minus everything codex counts as a permission override: the sandbox,
    /// the approval policy and the `sandbox_workspace_write` keys. `codex --remote … resume`
    /// refuses to start with any of them; the daemon receives them over `thread/resume`.
    var withoutPermissions: CodexThreadOptions {
        var copy = self
        copy.sandbox = nil
        copy.approvalPolicy = nil
        copy.addDirs = []
        copy.networkAccess = nil
        return copy
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
            reasoningEffort: project.reasoningEffort ?? global.reasoningEffort,
            reasoningSummary: project.reasoningSummary ?? global.reasoningSummary,
            verbosity: project.verbosity ?? global.verbosity,
            webSearch: project.webSearch ?? global.webSearch,
            networkAccess: project.networkAccess ?? global.networkAccess,
            developerInstructions: project.developerInstructions ?? global.developerInstructions,
            modelInstructionsFile: project.modelInstructionsFile ?? global.modelInstructionsFile
        )
    }
}
