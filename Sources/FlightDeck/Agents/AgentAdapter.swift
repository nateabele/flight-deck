import Foundation

/// Everything `SessionStore` needs from an agent, and nothing about how that agent works.
///
/// Four responsibilities: establish identity, produce the text typed into the pty, and
/// rename. Observation is deliberately NOT here — it belongs to `AgentRuntime`, because
/// both agents multiplex one app-wide source across N tabs rather than owning a per-tab
/// channel. See the design doc §2.1.
@MainActor
protocol AgentAdapter {
    static var id: AgentID { get }

    /// Establishes conversation identity BEFORE anything is typed into a terminal.
    ///
    /// This is the load-bearing method. Claude satisfies it by minting a UUID and binding
    /// the process to it; codex satisfies it by asking its app-server and being told. Either
    /// way the caller knows the conversation id and transcript path before a pty exists,
    /// which is what makes title sync and status attribution possible from the first byte.
    func prepare(for session: Session, options: AgentOptions) async throws -> AgentBinding

    func launchCommand(_ binding: AgentBinding, _ session: Session, _ options: AgentOptions) -> String
    func resumeCommand(_ binding: AgentBinding, _ session: Session, _ options: AgentOptions) -> String

    /// Renames the agent's own conversation. Claude types `/rename` into the pty; codex
    /// sends a request. Throwing is legal — the caller keeps the local title either way.
    func rename(_ binding: AgentBinding, to title: String) async throws
}
