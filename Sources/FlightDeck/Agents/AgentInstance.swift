import Foundation

/// One agent running as one account. The key for every registry that used to be keyed by
/// `AgentID` alone: the adapter, the runtime, and codex's app-server stack.
///
/// Keying by the agent alone was only ever right while an agent had one login. What binds a
/// process to a login is a home directory named by an environment variable (see
/// `AgentAdapter.environment(for:)`), so two logins are two processes, two transcript roots
/// and two `session_index.jsonl`s — nothing an agent-wide singleton can answer for.
///
/// `account` is optional for exactly one state: **no accounts are configured at all**, which
/// is what a store built without a `PreferencesStore` sees — every test that passes
/// `preferences: nil`, and a `-FlightDeckResetState` run. It does not mean "the built-in
/// account": `PreferencesStore.resolvedAccountID(for:in:)` answers a tab that names no account
/// with the *built-in* account's id whenever preferences holds one, so a nil key and an id key
/// can never both stand for the same home. That is the invariant this type exists to keep —
/// two keys on `~/.codex` would put two `codex app-server`s on one `session_index.jsonl`, and
/// each would only see half the renames.
///
/// The third case — a `Session.accountID` naming an account the user has since deleted — is
/// deliberately **not** a nil key, even though `resolvedAccountID` currently reports nil for
/// it. That session is broken, not homeless: running it under the built-in home would silently
/// sign the tab in as somebody else. It is refused before an instance is ever asked for; see
/// the accounts plan's gating task.
struct AgentInstance: Hashable, Sendable {
    let agent: AgentID
    let account: UUID?
}
