import FleetKit

/// Codex ships no transience flag — only a `codex_error_info` variant name — so the rule
/// lives here, as an allowlist.
///
/// Spellings are the ROLLOUT's (snake_case), not the app-server schema's (camelCase). The
/// two disagree for the same data; probed 2026-09-21 against codex-cli 0.155.1, where a
/// 429 wrote `response_too_many_failed_attempts` into the rollout's `task_complete` record.
@MainActor
struct CodexTurnRecovery: AgentTurnRecovery {
    /// The single source of truth for codex transience. `CodexEventMapper` calls this to
    /// populate `isTransient` at parse time, so the persisted flag and the retry decision
    /// cannot disagree.
    nonisolated static let transientKinds: Set<String> = [
        "rate_limit_exceeded",
        "server_overloaded",
        "internal_server_error",
        "response_too_many_failed_attempts",
        "response_stream_connection_failed",
        "response_stream_disconnected",
        "http_connection_failed",
    ]

    nonisolated static func isTransientKind(_ kind: String?) -> Bool {
        guard let kind else { return false }
        return transientKinds.contains(kind)
    }

    func retries(_ error: SessionAPIError) -> Bool {
        Self.isTransientKind(error.kind)
    }

    var resumeText: String { SessionStore.resumePrompt }
}
