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
        Set(sessions.repos.flatMap(\.sessions).compactMap(\.accountID))
    }

    /// The built-in account is what `Session.accountID == nil` resolves to, so removing it
    /// would strand every legacy tab. Bound accounts are refused for the ordinary reason:
    /// their tabs are pointing at conversations inside that home right now. Shared by the `−`
    /// button and by Relocate… in the context menu — an account whose home is in use must not
    /// be moved out from under its live tabs either.
    static func canRemove(_ account: AgentAccount, boundAccountIDs: Set<UUID>) -> Bool {
        !account.isBuiltIn && !boundAccountIDs.contains(account.id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Accounts")
                .font(.headline)

            List(selection: $selection) {
                ForEach(accounts) { account in
                    row(for: account)
                        .tag(account.id)
                }
                .onMove { offsets, destination in
                    preferences.preferences.moveAccounts(forAgent: agent, fromOffsets: offsets, toOffset: destination)
                }
            }
            .frame(minHeight: 100, maxHeight: 160)
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
                preferences.removeAccount(id: account.id)
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
        // The second, separately-confirmed destructive action (spec §8.3): that directory
        // holds OAuth credentials and every transcript for a login, so it is never reached by
        // the default button. Actually deleting it is out of scope for this pass — this wires
        // the two-step confirm the spec calls for; confirming here removes the registry entry
        // only, same as the non-destructive action, until a follow-up task adds the recursive
        // delete itself, gated the same way and never against a built-in home.
        .confirmationDialog(
            "Delete “\(pendingFileDelete?.home.path ?? "")”?",
            isPresented: Binding(get: { pendingFileDelete != nil }, set: { if !$0 { pendingFileDelete = nil } }),
            presenting: pendingFileDelete
        ) { account in
            Button("Delete", role: .destructive) {
                preferences.removeAccount(id: account.id)
                pendingFileDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingFileDelete = nil }
        } message: { _ in
            Text("This deletes every credential and transcript stored there. This cannot be undone.")
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
              AccountDraft.validate(home: chosen, editing: account.id, in: preferences) == .ok
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
    /// Reads the account's `LoginInvocation` off its adapter, opens an ordinary tab typing
    /// `command` verbatim (see `SessionStore.openSignInSession`), and — when `inject` is
    /// non-nil — queues it through the adapter's own injection closure once the tab settles,
    /// the same route `ClaudeAdapter.rename` already uses to type `/rename` into a running
    /// session.
    private func signIn(_ account: AgentAccount) {
        let adapter = sessions.adapter(for: account.agent, account: account.id)
        let invocation = adapter.loginInvocation(for: account)
        let directory = frontmostProjectPath ?? account.home.path
        let session = sessions.openSignInSession(for: account, in: directory, typing: invocation.command)
        guard let inject = invocation.inject, let claude = adapter as? ClaudeAdapter else { return }
        Task { await claude.injectRename(session.pinnedConversationID, inject) }
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
