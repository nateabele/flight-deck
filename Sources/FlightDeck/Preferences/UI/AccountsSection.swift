import AppKit
import IntakeKit
import SwiftUI

/// The account rules Settings → Accounts enforces (spec §8.1): the last-account refusal that
/// guards Remove, the built-in/live-session guard that gates Relocate…, and the two removal
/// warnings. Formerly the per-agent Accounts list view under the Agents tab; the list itself
/// is `AccountsSettingsTab` now (unify brief R7), and these stay here, pure and `static`, so
/// `AccountsSectionTests` can pin them without a SwiftUI body.
enum AccountsSection {
    /// The *resolved* ids, per spec §9: a tab whose `Session.accountID` is nil is bound to the
    /// agent's built-in account, not to nothing. Reading the raw field would let the built-in
    /// account look unbound while a legacy tab is running inside it. What this still guards is
    /// `canRelocate`: moving a home out from under a live tab leaves that tab's already-forked
    /// shell pointed at the old path. Removal no longer reads this set at all — tombstoning
    /// means a removed account keeps resolving by id, so a live tab loses nothing when its
    /// account is removed.
    ///
    /// Factored out `static` for the reason the rest of this file's predicates are: a SwiftUI
    /// body cannot be unit tested, and this rule can.
    @MainActor
    static func boundAccountIDs(in sessions: [Session], resolvedBy store: PreferencesStore) -> Set<UUID> {
        Set(sessions.compactMap { store.resolvedAccountID(for: $0.agent, in: $0.accountID) })
    }

    /// What the removal flow gates on: is there another live account for this agent to fall
    /// back to. Both the Remove action and `deleteFiles` read this — neither has a rule of its
    /// own.
    ///
    /// The only refusal left. Removal used to also refuse the built-in account and any account
    /// with a live tab — the first because a nil `Session.accountID` resolves to it, the
    /// second because dropping a record moved a running tab's runtime key. Tombstoning
    /// (`AgentAccount.removedAt`) answers both: a removed account still resolves by id, so
    /// neither the legacy tabs nor the running ones lose their identity. What remains is the
    /// one rule that is about the user rather than the machinery — an agent with no accounts
    /// at all has nothing to launch.
    ///
    /// `live` is the agent's already-filtered list (`Preferences.accounts(for:)`), so a
    /// tombstone can never count as the sibling that licenses a removal.
    static func canRemove(_ account: AgentAccount, among live: [AgentAccount]) -> Bool {
        live.contains { $0.id != account.id && !$0.isRemoved }
    }

    /// What `Relocate…` gates on — deliberately NOT `canRemove`'s rule, though it used to be
    /// the same predicate.
    ///
    /// Relocating is not removing. It moves the home directory itself, and a tab already
    /// running as this account has a forked shell whose `CLAUDE_CONFIG_DIR` still names the
    /// old path — so its watchers would follow the new home and see nothing. Relocating the
    /// built-in account is worse than useless: `isBuiltIn` is computed from the home, so
    /// moving it changes what a nil `Session.accountID` resolves to for every legacy tab.
    static func canRelocate(_ account: AgentAccount, boundAccountIDs: Set<UUID>) -> Bool {
        !account.isBuiltIn && !boundAccountIDs.contains(account.id)
    }

    /// The full guard chain the Remove confirmation must clear immediately before it
    /// acts — not only what disables the button, because the dialog can sit open while the
    /// account list changes underneath it.
    @MainActor
    @discardableResult
    static func remove(accountID: UUID, in store: PreferencesStore) -> Bool {
        guard let account = store.account(id: accountID), !account.isRemoved,
              canRemove(account, among: store.preferences.accounts(for: account.agent))
        else { return false }
        store.markAccountRemoved(id: accountID)
        return true
    }

    /// The full guard chain "Also Delete Files…" must clear immediately before it touches the
    /// filesystem. Re-reads the account fresh from `store` by id rather than trusting whatever
    /// `AgentAccount` value the caller is holding, so a relocate that raced the confirm dialog
    /// can never trash a since-abandoned home; `trash` always receives that freshly-read
    /// `account.home` and nothing else. Defaults `trash` to the real Trash so production call
    /// sites need not know this exists; tests substitute a spy to stay hermetic.
    ///
    /// Live sessions no longer refuse this. That is deliberate and is the accepted cost of "the
    /// button is never disabled": the second dialog names the sessions instead. See the spec's
    /// §5.7, where that risk is stated rather than designed around.
    @MainActor
    @discardableResult
    static func deleteFiles(
        accountID: UUID, in store: PreferencesStore,
        trash: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }
    ) -> Bool {
        guard let account = store.account(id: accountID), !account.isRemoved,
              canRemove(account, among: store.preferences.accounts(for: account.agent))
        else { return false }
        do {
            try trash(account.home)
        } catch {
            return false
        }
        return true
    }

    /// How many open tabs are running as this account, counted through the same resolution
    /// `boundAccountIDs` uses — so a legacy tab storing no account is counted against the
    /// built-in account it actually runs as, not against nothing.
    @MainActor
    static func boundSessionCount(
        for account: AgentAccount, in sessions: [Session], resolvedBy store: PreferencesStore
    ) -> Int {
        sessions.filter { store.resolvedAccountID(for: $0.agent, in: $0.accountID) == account.id }.count
    }

    /// The live-sessions sentence, or nothing when there are none. Separate from the two
    /// warnings below because both need it and neither should pad the common case with a
    /// "0 sessions" clause.
    private static func liveSessionsClause(_ count: Int) -> String {
        guard count > 0 else { return "" }
        let noun = count == 1 ? "1 open session " : "\(count) open sessions "
        return "\n\n\(noun)signed in to this account will keep running, but Flight Deck will "
            + "no longer offer this login."
    }

    /// The Remove confirmation. States permanence — removal is not re-seeded on the next
    /// launch — and that the directory itself is untouched, which is what separates this from
    /// the destructive button beside it.
    static func removalWarning(for account: AgentAccount, boundSessions: Int) -> String {
        "This can't be undone. The directory at \(account.home.path) is left in place."
            + liveSessionsClause(boundSessions)
    }

    /// The separately-confirmed destructive action. Names what is actually in that directory,
    /// because "delete files" undersells an OAuth credential and every transcript for a login.
    static func fileDeleteWarning(for account: AgentAccount, boundSessions: Int) -> String {
        "The credentials and transcripts at \(account.home.path) will be moved to the Trash. "
            + "This can't be undone from Flight Deck."
            + liveSessionsClause(boundSessions)
    }
}
