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
    func asThreadStartParams(cwd: String) -> [String: Any] {
        var params: [String: Any] = ["cwd": cwd]
        if let model { params["model"] = model }
        if let sandbox { params["sandbox"] = sandbox }
        if let approvalPolicy { params["approvalPolicy"] = approvalPolicy }
        if !addDirs.isEmpty { params["addDirs"] = addDirs }
        return params
    }
}
