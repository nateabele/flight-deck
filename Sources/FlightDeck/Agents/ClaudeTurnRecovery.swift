import FleetKit

/// Claude states transience itself, in the transcript record, and `ClaudeSession` already
/// parses it — so this defers rather than re-deriving a rule the CLI owns.
@MainActor
struct ClaudeTurnRecovery: AgentTurnRecovery {
    func retries(_ error: SessionAPIError) -> Bool { error.isTransient }
    var resumeText: String { SessionStore.resumePrompt }
}
