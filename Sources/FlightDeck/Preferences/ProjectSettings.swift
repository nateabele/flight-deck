import Foundation

/// One project's overrides. Absent entirely for a project the user has never configured, which
/// is the default state — the Projects pane opens on `<Use global settings>`.
///
/// `options` is keyed by agent so switching which agent the pane edits never discards the
/// other's values, and so a per-project override stays in force whenever that agent launches
/// here regardless of what `defaultAgent` currently says.
struct ProjectSettings: Codable, Equatable {
    /// nil = "use global settings": inherit the global agent order untouched.
    var defaultAgent: AgentID?
    /// A missing key means that agent's default account — the top of its list.
    var accounts: [AgentID: UUID]
    var options: [AgentID: AgentOptions]

    init(
        defaultAgent: AgentID? = nil,
        accounts: [AgentID: UUID] = [:],
        options: [AgentID: AgentOptions] = [:]
    ) {
        self.defaultAgent = defaultAgent
        self.accounts = accounts
        self.options = options
    }

    /// A record that says nothing is deleted rather than stored, matching how an emptied flag
    /// override already drops a project from the Projects list. A *present but empty* options
    /// payload says nothing, so it does not keep the record alive.
    var isEmpty: Bool {
        defaultAgent == nil && accounts.isEmpty && options.values.allSatisfy(\.isEmpty)
    }
}

extension AgentOptions {
    /// Whether this payload overrides anything. Per-agent, because "empty" is agent-shaped:
    /// claude's is an empty `FlagSet`, codex's is every field unset.
    var isEmpty: Bool {
        switch self {
        case .claude(let flags): return flags.isEmpty
        case .codex(let options):
            return options.model == nil && options.sandbox == nil
                && options.approvalPolicy == nil && options.addDirs.isEmpty
        }
    }
}
