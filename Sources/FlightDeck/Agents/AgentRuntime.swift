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
    /// unsubscribe. A value match on the conversation id still selects which `Source` an
    /// event comes from — sources are keyed by conversation id and looked up by value — but
    /// identity, not a value match, selects which tabs that source's events reach: each
    /// `Source` fans an event out only to the tabs whose tokens it issued, which is what
    /// stopped one event from writing 21 tabs. A future maintainer must preserve that
    /// narrower property: **a value match selects the source; identity selects the tabs.**
    func attach(
        _ binding: AgentBinding, for tab: UUID, onEvent: @escaping (AgentEvent) -> Void
    ) -> AttachmentToken
    func detach(_ token: AttachmentToken)
}
