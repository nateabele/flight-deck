import AppKit
import SwiftUI

/// The Accounts listbox under an agent's options pane (spec §8.1): every login this agent has,
/// drag-to-reorder — order is the "topmost wins when a project hasn't chosen" rule the caption
/// states — inline rename, and the guarded remove/relocate/sign-in affordances.
///
/// The predicates below are `static` and pure on purpose: a SwiftUI view body cannot be unit
/// tested, so every rule worth pinning — the built-in exemption, the live-sessions guard — is
/// factored out where `AccountsSectionTests` can call it directly. The view itself is a thin
/// shell over them.
struct AccountsSection: View {
    @ObservedObject var preferences: PreferencesStore
    @ObservedObject var sessions: SessionStore
    let agent: AgentID

    @State private var selection: UUID?
    @State private var showingAddSheet = false
    @State private var editingID: UUID?
    @State private var editingName = ""
    @State private var pendingRemoval: AgentAccount?
    @State private var pendingFileDelete: AgentAccount?
    @State private var justAdded: AgentAccount?

    private var accounts: [AgentAccount] { preferences.preferences.accounts(for: agent) }

    private var selectedAccount: AgentAccount? {
        accounts.first { $0.id == selection }
    }

    /// Every account with a tab open on it right now. `AgentAccount.id` is already scoped to
    /// one agent, so a session belonging to the other agent can never collide with it here.
    private var boundAccountIDs: Set<UUID> {
        Self.boundAccountIDs(in: sessions.repos.flatMap(\.sessions), resolvedBy: preferences)
    }

    /// The *resolved* ids, per spec §9: a tab whose `Session.accountID` is nil is bound to the
    /// agent's built-in account, not to nothing. Reading the raw field would let the built-in
    /// account look unbound while a legacy tab is running inside it — today the `isBuiltIn`
    /// exemption blocks that removal on its own, but the guard must not depend on a second rule
    /// staying in place. Removing an account out from under a live tab flips that tab's
    /// `AgentInstance` key mid-run, which strands its watchers and builds a second codex stack
    /// on the wrong home.
    ///
    /// Factored out `static` for the reason the rest of this file's predicates are: a SwiftUI
    /// body cannot be unit tested, and this rule can.
    @MainActor
    static func boundAccountIDs(in sessions: [Session], resolvedBy store: PreferencesStore) -> Set<UUID> {
        Set(sessions.compactMap { store.resolvedAccountID(for: $0.agent, in: $0.accountID) })
    }

    /// The built-in account is what `Session.accountID == nil` resolves to, so removing it
    /// would strand every legacy tab. Bound accounts are refused for the ordinary reason:
    /// their tabs are pointing at conversations inside that home right now. Shared by the `−`
    /// button and by Relocate… in the context menu — an account whose home is in use must not
    /// be moved out from under its live tabs either.
    static func canRemove(_ account: AgentAccount, boundAccountIDs: Set<UUID>) -> Bool {
        !account.isBuiltIn && !boundAccountIDs.contains(account.id)
    }

    /// The full guard chain "Remove from Flight Deck" must clear immediately before it drops the
    /// registry entry — not only what disables the `−` button, for the same reason `deleteFiles`
    /// re-checks: the confirmation dialog can sit open while a tab binds to this account.
    /// Removing it under a live tab flips that tab's `AgentInstance` key from `id` to nil
    /// mid-run, so its existing `statusWatchers[id]` / `codexStacks[id]` can no longer be
    /// matched by `stopStatusWatchingIfUnused` / `stopCodexIfUnused`, and the next runtime
    /// lookup builds a *second* codex stack at the nil key pointed at `builtInHome` — two
    /// app-servers, the new one tailing the wrong `session_index.jsonl`.
    @MainActor
    @discardableResult
    static func remove(
        accountID: UUID, boundAccountIDs: Set<UUID>, in store: PreferencesStore
    ) -> Bool {
        guard let account = store.account(id: accountID), !account.isBuiltIn,
              !boundAccountIDs.contains(accountID)
        else { return false }
        store.removeAccount(id: accountID)
        return true
    }

    /// The full guard chain "Also Delete Files…" must clear immediately before it touches the
    /// filesystem — not only what disables the menu item, which is one refactor away from being
    /// bypassed. Re-reads the account fresh from `store` by id rather than trusting whatever
    /// `AgentAccount` value the caller is holding, so a relocate that raced the confirm dialog
    /// can never trash a since-abandoned home; `trash` always receives that freshly-read
    /// `account.home` and nothing else, so there is no path in scope that isn't the account's
    /// own. Defaults `trash` to the real Trash so production call sites need not know this
    /// exists; tests substitute a spy to stay hermetic.
    @MainActor
    @discardableResult
    static func deleteFiles(
        accountID: UUID, boundAccountIDs: Set<UUID>, in store: PreferencesStore,
        trash: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }
    ) -> Bool {
        guard let account = store.account(id: accountID), !account.isBuiltIn,
              !boundAccountIDs.contains(accountID)
        else { return false }
        do {
            try trash(account.home)
        } catch {
            return false
        }
        return true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // No heading of its own: this renders as a `Section("Accounts")` inside the pane's
            // one `Form`, so drawing a second title here would stutter.
            List(selection: $selection) {
                ForEach(accounts) { account in
                    row(for: account)
                        .tag(account.id)
                }
                .onMove { offsets, destination in
                    preferences.preferences.moveAccounts(forAgent: agent, fromOffsets: offsets, toOffset: destination)
                }
            }
            // Sized to its contents rather than to a fixed box. Two accounts is the common
            // case and a flat 160pt left most of it empty; past four rows it scrolls instead
            // of pushing the sections below it off-screen.
            .frame(height: listHeight)
            .accessibilityIdentifier("accounts-list")

            HStack(spacing: 4) {
                Button {
                    showingAddSheet = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityIdentifier("accounts-add")

                Button {
                    guard let account = selectedAccount else { return }
                    pendingRemoval = account
                } label: {
                    Image(systemName: "minus")
                }
                .disabled(!(selectedAccount.map { Self.canRemove($0, boundAccountIDs: boundAccountIDs) } ?? false))
                .accessibilityIdentifier("accounts-remove")

                Spacer()
            }
            .buttonStyle(.borderless)
            .padding(.top, 2)

            Text("Projects that haven't chosen an account use the topmost one.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 12)
        .sheet(isPresented: $showingAddSheet) {
            AddAccountSheet(preferences: preferences, agent: agent) { account in
                justAdded = account
            }
        }
        .confirmationDialog(
            "Remove “\(pendingRemoval?.displayName ?? "")”?",
            isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
            presenting: pendingRemoval
        ) { account in
            Button("Remove from Flight Deck") {
                AccountsSection.remove(
                    accountID: account.id, boundAccountIDs: boundAccountIDs, in: preferences
                )
                pendingRemoval = nil
            }
            Button("Also Delete Files…", role: .destructive) {
                pendingFileDelete = account
                pendingRemoval = nil
            }
            Button("Cancel", role: .cancel) { pendingRemoval = nil }
        } message: { account in
            Text("The directory at \(account.home.path) is left in place.")
        }
        // The second, separately-confirmed destructive action (spec §8.3): that directory holds
        // OAuth credentials and every transcript for a login, so it is never reached by the
        // default button. Moves the directory to the Trash (recoverable, what "Delete Files"
        // means on the Mac) rather than unlinking it outright, and only then drops the registry
        // entry — `deleteFiles` re-checks the built-in/bound-session guards itself immediately
        // before touching disk, so this button can never act on either even if `.disabled`
        // above were ever wrong.
        .confirmationDialog(
            "Delete “\(pendingFileDelete?.home.path ?? "")”?",
            isPresented: Binding(get: { pendingFileDelete != nil }, set: { if !$0 { pendingFileDelete = nil } }),
            presenting: pendingFileDelete
        ) { account in
            Button("Delete", role: .destructive) {
                if AccountsSection.deleteFiles(accountID: account.id, boundAccountIDs: boundAccountIDs, in: preferences) {
                    preferences.removeAccount(id: account.id)
                }
                pendingFileDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingFileDelete = nil }
        } message: { account in
            Text("The directory at \(account.home.path) will be moved to the Trash.")
        }
        .alert(
            "Sign In to “\(justAdded?.displayName ?? "")”?",
            isPresented: Binding(get: { justAdded != nil }, set: { if !$0 { justAdded = nil } }),
            presenting: justAdded
        ) { account in
            Button("Sign In Now") {
                signIn(account)
                justAdded = nil
            }
            Button("Later", role: .cancel) { justAdded = nil }
        } message: { _ in
            Text("Opens a session tab to log in.")
        }
    }

    /// A row is two lines — display name over `email · organization` — so this is the pair
    /// plus its padding, not a single line height.
    private static let rowHeight: CGFloat = 38

    private var listHeight: CGFloat {
        CGFloat(min(max(accounts.count, 1), 4)) * Self.rowHeight + 8
    }

    @ViewBuilder
    private func row(for account: AgentAccount) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if editingID == account.id {
                TextField(
                    "Name", text: $editingName,
                    onCommit: { commitRename(account) }
                )
                .textFieldStyle(.plain)
                .onExitCommand { editingID = nil }
            } else {
                Text(account.displayName)
                    .onTapGesture(count: 2) { beginRename(account) }
            }
            Text(identityCaption(for: account))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .contextMenu {
            Button("Relocate…") { relocate(account) }
                .disabled(!Self.canRemove(account, boundAccountIDs: boundAccountIDs))
            Button("Sign In Again") { signIn(account) }
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([account.home])
            }
            Button("Refresh Identity") { refreshIdentity(account) }
        }
    }

    /// "email · organization" when both are known, whichever one is known when only one is,
    /// and a plain statement of fact when neither has been read yet — never a blank line,
    /// which would read as a loading state that never resolves.
    private func identityCaption(for account: AgentAccount) -> String {
        switch (account.cachedIdentity?.email, account.cachedIdentity?.organization) {
        case (let email?, let organization?): return "\(email) · \(organization)"
        case (let email?, nil): return email
        case (nil, let organization?): return organization
        case (nil, nil): return "Not signed in"
        }
    }

    private func beginRename(_ account: AgentAccount) {
        editingID = account.id
        editingName = account.displayName
    }

    private func commitRename(_ account: AgentAccount) {
        let trimmed = editingName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            preferences.renameAccount(id: account.id, to: trimmed)
        }
        editingID = nil
    }

    private func relocate(_ account: AgentAccount) {
        guard Self.canRemove(account, boundAccountIDs: boundAccountIDs),
              let chosen = FolderPicker.choose(),
              AccountDraft.validate(
                  home: chosen.path, agent: account.agent, editing: account.id, in: preferences
              ) == .ok
        else { return }
        preferences.relocateAccount(id: account.id, to: chosen)
    }

    private func refreshIdentity(_ account: AgentAccount) {
        guard let index = preferences.preferences.accounts.firstIndex(where: { $0.id == account.id })
        else { return }
        preferences.preferences.accounts[index].cachedIdentity =
            AccountDirectory.identity(atHome: account.home, agent: account.agent)
    }

    /// What both "Sign In Now" (from the Add sheet) and "Sign In Again" (from the context
    /// menu) call — there is nothing to distinguish a first login from a re-login, per the
    /// spec's "re-login needs no separate machinery" note.
    ///
    /// Reads the account's `LoginInvocation` off its adapter and hands the whole thing to the
    /// store, which owns both halves. This view used to unwrap the invocation itself and push
    /// the `/login` half through `ClaudeAdapter.injectRename` behind an `as? ClaudeAdapter`
    /// downcast — that downcast is what dragged the *rename* channel into a login, and a view
    /// has no business knowing which adapter class it is holding in the first place.
    private func signIn(_ account: AgentAccount) {
        let adapter = sessions.adapter(for: account.agent, account: account.id)
        let directory = frontmostProjectPath ?? account.home.path
        sessions.openSignInSession(
            for: account, in: directory, using: adapter.loginInvocation(for: account)
        )
    }

    /// The project Sign In opens its tab in: whichever project holds the currently selected
    /// session, or the topmost open project if none is selected. Falls back to the account's
    /// own home directory when nothing is open at all (spec §8.2) rather than refusing — a
    /// first login has to start somewhere.
    private var frontmostProjectPath: String? {
        if let selected = sessions.selectedSessionID,
           let repo = sessions.repos.first(where: { repo in repo.sessions.contains { $0.id == selected } }) {
            return repo.url.path
        }
        return sessions.repos.first?.url.path
    }
}
