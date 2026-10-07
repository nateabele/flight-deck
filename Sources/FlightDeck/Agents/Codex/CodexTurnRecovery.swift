import FleetKit
import IntakeKit

/// Codex ships no transience flag — only a `codex_error_info` variant name — so the rule is
/// an allowlist of kinds.
///
/// Spellings are the ROLLOUT's (snake_case), not the app-server schema's (camelCase). The
/// two disagree for the same data; probed 2026-09-21 against codex-cli 0.155.1, where a
/// 429 wrote `response_too_many_failed_attempts` into the rollout's `task_complete` record.
@MainActor
struct CodexTurnRecovery: AgentTurnRecovery {
    /// The single answer to codex transience. `CodexEventMapper` calls this to populate
    /// `isTransient` at parse time, so the persisted flag and the retry decision cannot
    /// disagree. The allowlist itself lives in the shared `AgentErrorVocabulary`, read through
    /// `CodexProfile`: every spelling this list held is there, still transient
    /// (`AgentProfileMigrationTests`), and claude's `overloaded`/`server_error` joined it.
    nonisolated static func isTransientKind(_ kind: String?) -> Bool {
        CodexProfile().isTransient(apiErrorKind: kind)
    }

    func retries(_ error: SessionAPIError) -> Bool {
        Self.isTransientKind(error.kind)
    }

    var resumeText: String { SessionStore.resumePrompt }
}
