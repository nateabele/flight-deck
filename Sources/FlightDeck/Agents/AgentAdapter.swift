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

    /// The binding for a tab whose conversation identity is ALREADY settled: one restored
    /// from a snapshot, or one the agent repointed at another conversation mid-flight.
    ///
    /// Separate from `prepare`, and synchronous, because those two cases are not identity
    /// negotiation — the store already holds the conversation id and is only asking the
    /// agent to describe what goes with it. Every path in `SessionStore` that needs one is
    /// synchronous up to `SessionStore.init` itself (`seedInitialSession` runs inside it),
    /// so an `async` answer there would mean creating tabs after the initializer returns.
    /// `prepare` stays `async` for the one case that genuinely negotiates: a new codex
    /// thread, which cannot be named until its app-server names it.
    func binding(for session: Session) -> AgentBinding

    func launchCommand(_ binding: AgentBinding, _ session: Session, _ options: AgentOptions) -> String
    func resumeCommand(_ binding: AgentBinding, _ session: Session, _ options: AgentOptions) -> String

    /// Renames the agent's own conversation. Claude types `/rename` into the pty; codex
    /// sends a request. Throwing is legal — the caller keeps the local title either way.
    func rename(_ binding: AgentBinding, to title: String) async throws
}
