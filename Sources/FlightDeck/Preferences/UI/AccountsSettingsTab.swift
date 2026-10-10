import AppKit
import IntakeKit
import SwiftUI

/// Settings → Accounts (unify brief R7): every login and pool Flight Deck can run agents as,
/// in ONE list, grouped by agent. A pool is a disclosure row with its accounts one level in;
/// drag a row to reorder it, into a pool to share that pool's limits, or out to top level.
///
/// Replaces the per-agent Accounts lists that lived under each agent in the Agents tab and the
/// pool editor in Flight Control → Capacity: those were two views of one thing (who you sign in
/// as, and how Flight Control leases them), and they disagreed about it.
///
/// Rows are rows in a grouped `Form` rather than a `List`, so the pane reads like the Routing
/// pane beside it. Every rule (grouping, what is hidden, what a drag does) is in
/// `AccountsPaneModel` and every removal guard in `AccountsSection`; this view only binds them.
struct AccountsSettingsTab: View {
    @ObservedObject var preferences: PreferencesStore
    @ObservedObject var sessions: SessionStore

    @State private var collapsed: Set<PoolID> = []
    /// The pool whose settings popover is open: a pool id, or an agent's `<agent>-default`.
    @State private var popover: PoolID?
    @State private var addingAccountFor: AgentChoice?
    @State private var addingPoolFor: AgentChoice?
    @State private var editingID: UUID?
    @State private var editingName = ""
    @State private var pendingRemoval: AgentAccount?
    @State private var pendingFileDelete: AgentAccount?
    @State private var pendingPoolRemoval: AccountPool?
    @State private var justAdded: AgentAccount?
    /// The row a drag is hovering, for the drop indicator.
    @State private var dropTargetRow: String?
    @State private var dropTargetGroupEnd: AgentID?
    @State private var dropError: String?

    init(preferences: PreferencesStore, sessions: SessionStore, popover: PoolID? = nil) {
        self.preferences = preferences
        self.sessions = sessions
        _popover = State(initialValue: popover)
    }

    private var list: AccountList { preferences.preferences.accountList }
    private var groups: [AccountsPaneModel.Group] { AccountsPaneModel.groups(list, collapsed: collapsed) }
    private var allSessions: [Session] { sessions.repos.flatMap(\.sessions) }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                ForEach(groups) { group in
                    Section {
                        if group.rows.isEmpty {
                            Text("No \(group.agent.displayName) accounts.")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(group.rows) { row in
                            rowView(row, in: group)
                        }
                    } header: {
                        groupHeader(group.agent)
                    } footer: {
                        groupFooter(group)
                    }
                }
            }
            .formStyle(.grouped)
            .accessibilityIdentifier("accounts-list")

            Divider()
            bottomBar
        }
        .sheet(item: $addingAccountFor) { choice in
            AddAccountSheet(preferences: preferences, agent: choice.agent) { justAdded = $0 }
        }
        .sheet(item: $addingPoolFor) { choice in
            AddPoolSheet(preferences: preferences, agent: choice.agent) { id in
                collapsed.remove(id)
                popover = id
            }
        }
        .confirmationDialog(
            "Remove “\(pendingRemoval?.displayName ?? "")”?",
            isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
            presenting: pendingRemoval
        ) { account in
            Button("Remove from Flight Deck") {
                AccountsSection.remove(accountID: account.id, in: preferences)
                pendingRemoval = nil
            }
            Button("Also Delete Files…", role: .destructive) {
                pendingFileDelete = account
                pendingRemoval = nil
            }
            Button("Cancel", role: .cancel) { pendingRemoval = nil }
        } message: { account in
            Text(AccountsSection.removalWarning(for: account, boundSessions: boundSessions(account)))
        }
        // The second, separately-confirmed destructive action: that directory holds OAuth
        // credentials and every transcript for a login, so it is never the default button.
        // `deleteFiles` re-reads the account and re-checks the last-account rule right before it
        // touches disk.
        .confirmationDialog(
            "Delete “\(pendingFileDelete?.home.path ?? "")”?",
            isPresented: Binding(get: { pendingFileDelete != nil }, set: { if !$0 { pendingFileDelete = nil } }),
            presenting: pendingFileDelete
        ) { account in
            Button("Delete", role: .destructive) {
                if AccountsSection.deleteFiles(accountID: account.id, in: preferences) {
                    preferences.markAccountRemoved(id: account.id)
                }
                pendingFileDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingFileDelete = nil }
        } message: { account in
            Text(AccountsSection.fileDeleteWarning(for: account, boundSessions: boundSessions(account)))
        }
        .confirmationDialog(
            "Remove the pool “\(pendingPoolRemoval?.label ?? "")”?",
            isPresented: Binding(get: { pendingPoolRemoval != nil }, set: { if !$0 { pendingPoolRemoval = nil } }),
            presenting: pendingPoolRemoval
        ) { pool in
            Button("Remove Pool", role: .destructive) {
                try? preferences.removePool(pool.id)
                pendingPoolRemoval = nil
            }
            Button("Cancel", role: .cancel) { pendingPoolRemoval = nil }
        } message: { pool in
            Text(Self.poolRemovalWarning(pool, assignedProjects: assignedProjects(pool.id)))
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
        .alert("Can't Move That There", isPresented: Binding(get: { dropError != nil }, set: { if !$0 { dropError = nil } })) {
            Button("OK", role: .cancel) { dropError = nil }
        } message: {
            Text(dropError ?? "")
        }
    }

    /// Pool removal never removes a login; what it does undo is every project billing the pool.
    static func poolRemovalWarning(_ pool: AccountPool, assignedProjects: Int) -> String {
        let accounts = pool.members.filter { !$0.isRemoved }.count
        var text = accounts == 0
            ? "The pool has no accounts."
            : "Its \(accounts == 1 ? "account stays" : "\(accounts) accounts stay") in the list, outside any pool."
        if assignedProjects > 0 {
            text += " \(assignedProjects == 1 ? "One project uses" : "\(assignedProjects) projects use") this pool and will go back to the default account."
        }
        return text
    }

    private func assignedProjects(_ pool: PoolID) -> Int {
        preferences.preferences.projectSettings.values.filter { $0.accounts.values.contains(.pool(pool)) }.count
    }

    // MARK: Group chrome

    private func groupHeader(_ agent: AgentID) -> some View {
        HStack(spacing: 8) {
            Text(agent.displayName)
            Spacer()
            let defaultID = CapacityPool.defaultID(for: agent)
            // Only while the default pool exists — it is the agent's accounts outside any pool,
            // so with every account pooled there is nothing for its limits to apply to.
            if preferences.effectivePools.contains(where: { $0.id == defaultID }) {
                Button("Limits for Unpooled Accounts…") { popover = defaultID }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .help("The soft and hard limits of \(agent.displayName) accounts that are not in a pool")
                    .accessibilityIdentifier("accounts-default-pool-\(agent.rawValue)")
                    .popover(isPresented: popoverBinding(defaultID), arrowEdge: .bottom) {
                        PoolSettingsPopover(preferences: preferences, poolID: defaultID, agent: agent,
                                            close: { popover = nil })
                    }
            }
        }
    }

    /// The footer says what the order means, and doubles as the drop zone for "last at top
    /// level" — the one place a row can be dropped that is not another row.
    private func groupFooter(_ group: AccountsPaneModel.Group) -> some View {
        let caption: String = {
            if group.agent == .gemini { return "Gemini signs in through the system keychain, so it has one account." }
            guard let first = list.accounts.first(where: { $0.id == group.defaultAccountID }) else {
                return "Projects use the agent's own sign-in."
            }
            return "Projects that haven't chosen an account use “\(first.displayName)”, the topmost."
        }()
        return Text(caption)
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 2)
            .overlay(alignment: .top) {
                if dropTargetGroupEnd == group.agent { dropLine }
            }
            .dropDestination(for: String.self) { items, _ in
                perform(items, on: .endOfGroup(group.agent))
            } isTargeted: { dropTargetGroupEnd = $0 ? group.agent : (dropTargetGroupEnd == group.agent ? nil : dropTargetGroupEnd) }
    }

    private var bottomBar: some View {
        HStack(spacing: 10) {
            Menu {
                Button("Add Account…") { addingAccountFor = AgentChoice(agent: .claude) }
                    .accessibilityIdentifier("accounts-add-account")
                Button("Add Pool…") { addingPoolFor = AgentChoice(agent: .claude) }
                    .accessibilityIdentifier("accounts-add-pool")
            } label: {
                Image(systemName: "plus")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Add an account or a pool")
            .accessibilityIdentifier("accounts-add")
            Text("Drag an account onto a pool to share its limits. Drag within a group to reorder.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: Rows

    @ViewBuilder
    private func rowView(_ row: AccountsPaneModel.Row, in group: AccountsPaneModel.Group) -> some View {
        switch row {
        case .account(let account):
            accountRow(account, pool: nil, isDefault: account.id == group.defaultAccountID)
                .overlay(alignment: .top) { if dropTargetRow == row.id { dropLine } }
                .draggable(AccountsPaneModel.payload(.account(account.id)))
                .dropDestination(for: String.self) { items, _ in
                    perform(items, on: .before(.account(account.id)))
                } isTargeted: { setTarget(row.id, $0) }
        case .member(let account, let pool):
            accountRow(account, pool: pool, isDefault: account.id == group.defaultAccountID)
                .padding(.leading, Self.iconColumn + Self.iconSpacing)
                .overlay(alignment: .top) {
                    if dropTargetRow == row.id { dropLine.padding(.leading, Self.iconColumn + Self.iconSpacing) }
                }
                .draggable(AccountsPaneModel.payload(.account(account.id)))
                .dropDestination(for: String.self) { items, _ in
                    perform(items, on: .intoPool(pool, before: account.id))
                } isTargeted: { setTarget(row.id, $0) }
        case .pool(let pool):
            poolRow(pool)
                .background {
                    if dropTargetRow == row.id {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.accentColor.opacity(0.14))
                            .padding(.horizontal, -8)
                            .padding(.vertical, -4)
                    }
                }
                .draggable(AccountsPaneModel.payload(.pool(pool.id)))
                .dropDestination(for: String.self) { items, _ in
                    perform(items, on: .intoPool(pool.id, before: nil))
                } isTargeted: { setTarget(row.id, $0) }
        }
    }

    private var dropLine: some View {
        Rectangle().fill(Color.accentColor).frame(height: 2).offset(y: -6)
    }

    private func setTarget(_ id: String, _ targeted: Bool) {
        if targeted { dropTargetRow = id } else if dropTargetRow == id { dropTargetRow = nil }
    }

    private func perform(_ items: [String], on target: AccountsPaneModel.DropTarget) -> Bool {
        dropTargetRow = nil
        dropTargetGroupEnd = nil
        guard let payload = items.first, let id = AccountsPaneModel.entryID(fromPayload: payload) else { return false }
        do throws(AccountListError) {
            try preferences.updateAccountList { list throws(AccountListError) in
                try AccountsPaneModel.drop(id, on: target, in: &list)
            }
            return true
        } catch {
            if case .agentMismatch(let from, let to) = error {
                dropError = "A \(to.displayName) group or pool holds only \(to.displayName) accounts, and this is a \(from.displayName) account."
            }
            return false
        }
    }

    /// Every row's leading icon sits in one column this wide, so account, pool and member text
    /// all start on a shared edge (members one column further in).
    static let iconColumn: CGFloat = 26
    static let iconSpacing: CGFloat = 10

    private func accountRow(_ account: AgentAccount, pool: PoolID?, isDefault: Bool) -> some View {
        HStack(spacing: Self.iconSpacing) {
            Image(systemName: account.cachedIdentity == nil ? "person.crop.circle.badge.questionmark" : "person.crop.circle.fill")
                .font(.title2)
                .foregroundStyle(account.cachedIdentity == nil ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                .frame(width: Self.iconColumn)
                .accessibilityLabel(account.cachedIdentity == nil ? "Not signed in" : "Signed in")
            VStack(alignment: .leading, spacing: 2) {
                if editingID == account.id {
                    TextField("Name", text: $editingName, onCommit: { commitRename(account) })
                        .textFieldStyle(.plain)
                        .onExitCommand { editingID = nil }
                } else {
                    Text(account.displayName)
                        .onTapGesture(count: 2) { beginRename(account) }
                }
                Text(AccountsPaneModel.identityCaption(account))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if isDefault {
                Text("Default")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.primary.opacity(0.07)))
                    .help("Projects that haven't chosen an account use this one")
            }
            Menu {
                accountActions(account, pool: pool)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityIdentifier("account-actions-\(account.displayName)")
        }
        .contentShape(Rectangle())
        .contextMenu { accountActions(account, pool: pool) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("account-row-\(account.displayName)")
    }

    @ViewBuilder
    private func accountActions(_ account: AgentAccount, pool: PoolID?) -> some View {
        Button("Rename") { beginRename(account) }
        Button("Sign In Again") { signIn(account) }
        Button("Relocate…") { relocate(account) }
            .disabled(!AccountsSection.canRelocate(account, boundAccountIDs: boundAccountIDs))
        Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([account.home]) }
        Button("Refresh Identity") { refreshIdentity(account) }
        let pools = list.pools.filter { $0.agent == account.agent && !$0.isDefault && $0.id != pool }
        if !pools.isEmpty || pool != nil {
            Menu("Move to Pool") {
                ForEach(pools) { p in
                    Button(p.label) { _ = perform([AccountsPaneModel.payload(.account(account.id))], on: .intoPool(p.id, before: nil)) }
                }
                if pool != nil {
                    if !pools.isEmpty { Divider() }
                    Button("Out of Pool") {
                        _ = perform([AccountsPaneModel.payload(.account(account.id))], on: .endOfGroup(account.agent))
                    }
                }
            }
        }
        Divider()
        Button("Remove…") { pendingRemoval = account }
            .disabled(!AccountsSection.canRemove(account, among: preferences.preferences.accounts(for: account.agent)))
    }

    private func poolRow(_ pool: AccountPool) -> some View {
        let isCollapsed = collapsed.contains(pool.id)
        return HStack(spacing: Self.iconSpacing) {
            Image(systemName: "square.stack.3d.up.fill")
                .font(.title2)
                .foregroundStyle(Color.accentColor)
                .frame(width: Self.iconColumn)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(pool.label)
                Text(AccountsPaneModel.summary(of: pool))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            // The disclosure control sits with the row's other controls rather than in the icon
            // column, so a pool's name starts on the same edge as every account's.
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    if isCollapsed { collapsed.remove(pool.id) } else { collapsed.insert(pool.id) }
                }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.borderless)
            .help(isCollapsed ? "Show accounts" : "Hide accounts")
            .accessibilityLabel(isCollapsed ? "Expand" : "Collapse")
            .accessibilityIdentifier("pool-disclosure-\(pool.label)")
            Button {
                popover = pool.id
            } label: {
                Image(systemName: "slider.horizontal.3")
            }
            .buttonStyle(.borderless)
            .help("Pool settings")
            .accessibilityIdentifier("pool-settings-\(pool.label)")
            .popover(isPresented: popoverBinding(pool.id), arrowEdge: .trailing) {
                PoolSettingsPopover(preferences: preferences, poolID: pool.id, agent: pool.agent,
                                    localAgents: CapacityPane.defaultLocalAgents(),
                                    onRemove: { popover = nil; pendingPoolRemoval = pool },
                                    close: { popover = nil })
            }
            Menu {
                Button("Settings…") { popover = pool.id }
                Divider()
                Button("Remove Pool…") { pendingPoolRemoval = pool }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .contentShape(Rectangle())
        .contextMenu {
            Button("Settings…") { popover = pool.id }
            Button("Remove Pool…") { pendingPoolRemoval = pool }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("pool-row-\(pool.label)")
    }

    private func popoverBinding(_ id: PoolID) -> Binding<Bool> {
        Binding(get: { popover == id }, set: { if !$0, popover == id { popover = nil } })
    }

    // MARK: Account actions

    private var boundAccountIDs: Set<UUID> {
        AccountsSection.boundAccountIDs(in: allSessions, resolvedBy: preferences)
    }

    private func boundSessions(_ account: AgentAccount) -> Int {
        AccountsSection.boundSessionCount(for: account, in: allSessions, resolvedBy: preferences)
    }

    private func beginRename(_ account: AgentAccount) {
        editingID = account.id
        editingName = account.displayName
    }

    private func commitRename(_ account: AgentAccount) {
        let trimmed = editingName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { preferences.renameAccount(id: account.id, to: trimmed) }
        editingID = nil
    }

    private func relocate(_ account: AgentAccount) {
        guard AccountsSection.canRelocate(account, boundAccountIDs: boundAccountIDs),
              let chosen = FolderPicker.choose(),
              AccountDraft.validate(home: chosen.path, agent: account.agent, editing: account.id, in: preferences) == .ok
        else { return }
        preferences.relocateAccount(id: account.id, to: chosen)
    }

    private func refreshIdentity(_ account: AgentAccount) {
        guard let index = preferences.preferences.accounts.firstIndex(where: { $0.id == account.id }) else { return }
        preferences.preferences.accounts[index].cachedIdentity =
            AccountDirectory.identity(atHome: account.home, agent: account.agent)
    }

    /// "Sign In Now" and "Sign In Again" are the same thing: the account's own adapter's login
    /// invocation, run in a tab the store opens. See `SessionStore.openSignInSession`.
    private func signIn(_ account: AgentAccount) {
        let adapter = sessions.adapter(for: account.agent, account: account.id)
        sessions.openSignInSession(for: account, in: frontmostProjectPath ?? account.home.path,
                                   using: adapter.loginInvocation(for: account))
    }

    /// The project Sign In opens its tab in: the selected session's, else the topmost open
    /// project, else the account's own home — a first login has to start somewhere.
    private var frontmostProjectPath: String? {
        if let selected = sessions.selectedSessionID,
           let repo = sessions.repos.first(where: { $0.sessions.contains { $0.id == selected } }) {
            return repo.url.path
        }
        return sessions.repos.first?.url.path
    }
}

/// A sheet's subject. A wrapper rather than `AgentID: Identifiable`: that would be a retroactive
/// conformance on IntakeKit's type, which another module could make too.
private struct AgentChoice: Identifiable {
    let agent: AgentID
    var id: AgentID { agent }
}
