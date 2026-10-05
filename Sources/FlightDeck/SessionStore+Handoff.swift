import Foundation

extension AgentID {
    /// The slash command that ends this agent's TUI and returns its tab to the shell (verified
    /// against each TUI; see the L3-U plan Task 14 Step 1).
    var exitCommand: String {
        switch self {
        case .claude: return "/exit"
        case .codex: return "/quit"
        }
    }
}

extension SessionStore {
    /// Ends a handed-off agent but keeps its tab, whose scrollback is the hand-off's history
    /// (L3-U §5.7). Typed rather than signalled: the process the tab runs is the shell, and
    /// killing the agent's pid would mean resolving which descendant it is — the exit command
    /// gets the TUI to leave on its own and the shell prompt comes back.
    ///
    /// A dialog still open is refused first: the agent is being retired, so denying whatever it
    /// was about to do is right, and an exit command typed into a dialog would land in the
    /// dialog. `submitPrompt` queues the command until the composer is back.
    @discardableResult
    func retireAgent(_ id: UUID) -> PromptDispatch {
        if statuses[id]?.activity == .waiting { interruptTurn(id, includingDialog: true) }
        let agent = repos.flatMap(\.sessions).first { $0.id == id }?.agent ?? .claude
        return submitPrompt(agent.exitCommand, token: UUID(), to: id)
    }
}
