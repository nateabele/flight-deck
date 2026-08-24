import Foundation

/// The observation half of an agent integration, kept off `AgentAdapter` because both
/// agents multiplex ONE source per account across that account's tabs: claude's status
/// registry is a single flat pid-keyed directory inside a `CLAUDE_CONFIG_DIR`, and a codex
/// app-server owns every thread it created inside one `CODEX_HOME`. A per-session runtime
/// would re-scan the registry N times for claude and, for codex, lose every thread the
/// moment its short-lived process exited. See `SessionStore.runtimes`, keyed by
/// `AgentInstance` (agent + account), not by agent alone.
@MainActor
protocol AgentRuntime: AnyObject {
    /// Subscribes `tab` to `binding`'s conversation. The returned token is the only way to
    /// unsubscribe, and the only thing that decides who an event reaches — deliberately not
    /// a value match on the conversation id, which is what let one event write 21 tabs.
    func attach(
        _ binding: AgentBinding, for tab: UUID, onEvent: @escaping (AgentEvent) -> Void
    ) -> AttachmentToken
    func detach(_ token: AttachmentToken)
}
