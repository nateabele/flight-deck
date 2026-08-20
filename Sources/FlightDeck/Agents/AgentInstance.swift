import Foundation

/// One agent running as one account. The key for every registry that used to be keyed by
/// `AgentID` alone: the adapter, the runtime, and codex's app-server stack.
///
/// Keying by the agent alone was only ever right while an agent had one login. What binds a
/// process to a login is a home directory named by an environment variable (see
/// `AgentAdapter.environment(for:)`), so two logins are two processes, two transcript roots
/// and two `session_index.jsonl`s — nothing an agent-wide singleton can answer for.
///
/// `account` is nil in exactly the states where `PreferencesStore.resolvedAccountID(for:in:)`
/// has no **isBuiltIn** account for the agent to name. That is more than "there is no
/// `PreferencesStore`" — which is what a store built with `preferences: nil` sees, every test
/// that passes it and a `-FlightDeckResetState` run. It also covers preferences that hold
/// accounts but no built-in one for this agent: a built-in account relocated away from
/// `~/.claude`, or a migration run against a root that is not `$HOME`.
///
/// It never means "the built-in account", and the invariant holds in every one of those states
/// for one reason: **with no isBuiltIn account registered there is no id-keyed instance for
/// that home either, so a nil key and an id key can never name the same home.** Register one
/// and every tab that stores no account resolves to its id instead, so the nil key stops being
/// produced at all. That is the invariant this type exists to keep — two keys on `~/.codex`
/// would put two `codex app-server`s on one `session_index.jsonl`, and each would only see
/// half the renames.
///
/// One further state is deliberately **not** a nil key, even though `resolvedAccountID`
/// currently reports nil for it: a `Session.accountID` naming an account the user has since
/// deleted. That session is broken, not homeless: running it under the built-in home would
/// silently sign the tab in as somebody else. It is refused before an instance is ever asked for; see
/// the accounts plan's gating task.
struct AgentInstance: Hashable, Sendable {
    let agent: AgentID
    let account: UUID?
}
