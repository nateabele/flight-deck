import SwiftUI
import IntakeKit

/// Per-project overrides. The project list is the union of currently-open projects and
/// projects with a saved override — an override outlives the project it belongs to, since
/// closing a project removes it from `SessionStore` entirely.
///
/// The detail pane is three sections: which agent (also the project's default, per
/// `ProjectSettings.defaultAgent`), which account or pool each agent bills here, and that
/// agent's options.
/// The Agent picker doubles as both the default-agent setter AND the selector for what the
/// sections below edit — but a per-project override applies whenever that agent launches here
/// regardless of what the picker currently shows, so `hiddenOverrideSummary` names whichever
/// other agent still has one in force while it is off-screen.
struct ProjectsSettingsTab: View {
    @ObservedObject var preferences: PreferencesStore
    @ObservedObject var sessions: SessionStore

    /// The selection lives on the store, not in `@State`, so a caller outside this view can
    /// point the pane at one project — "Configure…" on a sidebar project row opens Settings
    /// here with that project already picked. See `PreferencesOpener.select`.
    private var selected: String? { preferences.selectedProjectPath }
    private var selection: Binding<String?> {
        Binding(
            get: { preferences.selectedProjectPath },
            set: { preferences.selectedProjectPath = $0 }
        )
    }

    private var paths: [String] {
        let open = sessions.repos.map(\.url.standardizedFileURL.path)
        return Array(Set(open).union(preferences.configuredProjectPaths)).sorted()
    }

    var body: some View {
        VStack(spacing: 0) {
            // `HSplitView`, matching the Agents tab, NOT `NavigationSplitView`. On macOS the
            // navigation variant is a window-level container: it injects a sidebar-toggle
            // button into the toolbar, re-centres the window title over the detail column
            // alone, and renders its sidebar as an inset panel with capsule selection. Inside
            // a preferences tab that produced a pane visibly unlike every sibling tab, with
            // the tab strip pushed off-centre.
            HSplitView {
                List(paths, id: \.self, selection: selection) { path in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(URL(fileURLWithPath: path).lastPathComponent)
                        Text(path)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                    .badge(preferences.projectSettings(path).isEmpty ? nil : Text("override"))
                    .tag(path)
                }
                // The same numbers the Agents list uses; paths already truncate from the head.
                .frame(minWidth: 140, idealWidth: 160, maxWidth: 280)
                .onChange(of: paths) { _, newPaths in
                    // Covers both "Remove Overrides" and reverting every override to empty
                    // (which also removes the record, see the option bindings below): either
                    // can drop the selected path from the list out from under the detail pane.
                    if let selected, !newPaths.contains(selected) {
                        preferences.selectedProjectPath = nil
                    }
                }

                Group {
                    if let selected {
                        detail(for: selected)
                    } else {
                        ContentUnavailableView(
                            "No Project Selected",
                            systemImage: "folder",
                            description: Text("Select a project to override its agent options.")
                        )
                    }
                }
                .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
            }

            Divider()
            HStack {
                // HIG requires a suppressed alert to stay recoverable; this is the recovery.
                // Phrased as the question rather than the suppression — a checkbox whose
                // label is a negative is one people read backwards.
                Toggle(
                    "Confirm before closing a project with multiple sessions",
                    isOn: Binding(
                        get: { preferences.confirmsProjectClose },
                        set: { preferences.confirmsProjectClose = $0 }
                    )
                )
                .accessibilityIdentifier("prefs-confirm-project-close")
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
    }

    @ViewBuilder
    private func detail(for path: String) -> some View {
        let settings = preferences.projectSettings(path)
        // Falls back the same way `AgentsSettingsTab` does: with nothing selected — here,
        // `<Use global settings>` — the sections below still need a concrete agent to edit.
        let selectedAgent = settings.defaultAgent ?? preferences.preferences.agents.first?.id ?? .claude

        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(path).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Remove Overrides") {
                    preferences.setProjectSettings(path, ProjectSettings())
                }
                .disabled(settings.isEmpty)
                .accessibilityIdentifier("project-remove-overrides")
            }
            .padding(.horizontal, 14)
            // Symmetric, and enough of it that the button is not wearing the row as a collar:
            // this was `.top, 8` with no bottom at all, so the button's lower edge sat flush
            // against the form below it.
            .padding(.vertical, 12)

            // Same shape as the Agents pane: one scrolling `Form` per agent, its leading
            // sections supplied by the caller and its launch command last. This pane used to
            // stack a 220pt `Form` above a separate options view, which gave the two panes
            // different layouts for the same job and squeezed the flags into whatever height
            // was left.
            let sections = {
                AnyView(
                    Group {
                        Section("Agent") {
                            Picker("Agent", selection: agentBinding(for: path)) {
                                Text("<Use global settings>").tag(AgentID?.none)
                                // Tab-ready agents only (unify brief R4): this choice is what ⌘N
                                // opens here, and grok/gemini cannot run a tab until their
                                // adapters are real.
                                ForEach(AgentID.tabReadyCases, id: \.self) { agent in
                                    Text(agent.displayName).tag(AgentID?.some(agent))
                                }
                            }
                            .labelsHidden()
                            .accessibilityIdentifier("project-agent-picker")

                            if let summary = Self.hiddenOverrideSummary(settings, excluding: selectedAgent) {
                                Text(summary)
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                        }

                        // One row per agent with a choice to make, not just the agent being
                        // edited: a project can run several agents (planning seats included),
                        // and each bills its own assignment (unify brief R8).
                        let list = preferences.preferences.accountList
                        let choosable = AgentID.allCases.filter {
                            Self.showsAccountPicker(for: $0, in: list, assigned: settings.accounts[$0])
                        }
                        if !choosable.isEmpty {
                            Section {
                                ForEach(choosable, id: \.self) { agent in
                                    LabeledContent(agent.displayName) {
                                        accountPicker(for: path, agent: agent, assigned: settings.accounts[agent])
                                    }
                                }
                            } header: {
                                Text("Accounts")
                            } footer: {
                                Text("A pool gives each new tab and planning run the first of its accounts under the pool's soft limit.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                )
            }

            Group {
                switch selectedAgent {
                case .codex:
                    CodexOptionsForm(
                        preferences: preferences,
                        projectOverride: codexOptionsBinding(for: path),
                        header: sections
                    )
                default:
                    FlagEditor(
                        flags: claudeFlagsBinding(for: path),
                        inherited: globalClaudeFlags,
                        lockedPrefix: ClaudeOptionsPane.placeholderPrefix,
                        header: sections
                    )
                }
            }
            .frame(maxHeight: .infinity)
            .id(path)
        }
    }

    /// Overrides belonging to an agent the pane is not currently showing. They stay in force
    /// regardless of the dropdown — the dropdown picks what you edit and what ⌘N launches, not
    /// whether an override applies — so leaving them unmentioned would make them invisible and
    /// active at the same time.
    static func hiddenOverrideSummary(_ settings: ProjectSettings, excluding shown: AgentID?) -> String? {
        let hidden = AgentID.allCases.filter { agent in
            agent != shown && !(settings.options[agent]?.isEmpty ?? true)
        }
        guard !hidden.isEmpty else { return nil }
        let names = hidden.map(\.displayName)
        return "\(names.joined(separator: " and ")) \(hidden.count == 1 ? "has" : "have") project overrides. Select \(names.joined(separator: " or ")) to edit them."
    }

    /// The global claude row's flags, read the same way `ClaudeOptionsPane` and
    /// `PreferencesStore.resolvedOptions(for:project:)` do — by id within `preferences.agents`,
    /// not the decode-only legacy `globalFlags` field, so this pane's "inherited" preview can
    /// never show a value that a launch would not actually apply.
    private var globalClaudeFlags: FlagSet {
        guard case .claude(let flags)? = preferences.preferences.agents
            .first(where: { $0.id == .claude })?.options
        else { return FlagSet() }
        return flags
    }

    private func agentBinding(for path: String) -> Binding<AgentID?> {
        Binding(
            get: { preferences.projectSettings(path).defaultAgent },
            set: { newValue in
                var settings = preferences.projectSettings(path)
                settings.defaultAgent = newValue
                preferences.setProjectSettings(path, settings)
            }
        )
    }

    /// One choice in the Account picker: nil is "Default" (the agent's topmost account).
    struct AccountOption: Equatable {
        var value: AccountAssignment?
        var title: String
        var isPool: Bool
    }

    /// What a project can bill `agent`'s work to (unify brief R8): Default — naming the account
    /// it means today — then each live account of the agent in list order, then each of its
    /// pools: the user's pools in list order, and last the agent's default pool (its unpooled
    /// accounts), when it has one. Local pools are left out: they lease an endpoint slot, not an
    /// account a tab could sign in as.
    static func accountOptions(for agent: AgentID, in list: AccountList) -> [AccountOption] {
        let accounts = list.accounts.filter { $0.agent == agent && !$0.isRemoved }
        var options = [AccountOption(value: nil, title: accounts.first.map { "Default (\($0.displayName))" } ?? "Default",
                                     isPool: false)]
        options += accounts.map { AccountOption(value: .account($0.id), title: $0.displayName, isPool: false) }
        let effective = list.effectivePools().filter { $0.agent == agent && $0.kind == .hosted }
        options += effective.filter { !$0.isDefault }.map { AccountOption(value: .pool($0.id), title: $0.label, isPool: true) }
        options += effective.filter(\.isDefault).map { AccountOption(value: .pool($0.id), title: $0.label, isPool: true) }
        return options
    }

    /// Whether there is anything to choose: two accounts, or a pool the user made. (A lone
    /// account's synthesized default pool is that same account, so it is no choice.) Always when
    /// the project already names something, so a stale or pool assignment can be seen and undone.
    static func showsAccountPicker(for agent: AgentID, in list: AccountList, assigned: AccountAssignment?) -> Bool {
        if assigned != nil { return true }
        let accounts = list.accounts.filter { $0.agent == agent && !$0.isRemoved }
        let userPools = list.pools.filter { $0.agent == agent && !$0.isDefault && $0.kind == .hosted }
        return accounts.count > 1 || !userPools.isEmpty
    }

    @ViewBuilder
    private func accountPicker(for path: String, agent: AgentID, assigned: AccountAssignment?) -> some View {
        let options = Self.accountOptions(for: agent, in: preferences.preferences.accountList)
        Picker("Account", selection: accountBinding(for: path, agent: agent)) {
            // By position: two accounts may share a display name.
            ForEach(Array(options.filter { !$0.isPool }.enumerated()), id: \.offset) { _, option in
                Text(option.title).tag(option.value)
            }
            let pools = options.filter(\.isPool)
            if !pools.isEmpty {
                Divider()
                ForEach(Array(pools.enumerated()), id: \.offset) { _, option in
                    Label(option.title, systemImage: "square.stack.3d.up").tag(option.value)
                }
            }
            // An assignment that names something gone still has to be shown as what it is, or
            // the picker silently reads "Default" while launches are refused as BROKEN.
            if let assigned, !options.contains(where: { $0.value == assigned }) {
                Divider()
                Text("Missing \(assigned.poolID == nil ? "account" : "pool")").tag(AccountAssignment?.some(assigned))
            }
        }
        .labelsHidden()
        .fixedSize()
        .accessibilityIdentifier("project-account-picker-\(agent.rawValue)")
    }

    /// Writes an account or a pool assignment; Default clears the agent's assignment.
    private func accountBinding(for path: String, agent: AgentID) -> Binding<AccountAssignment?> {
        Binding(
            get: { preferences.projectSettings(path).accounts[agent] },
            set: { newValue in
                var settings = preferences.projectSettings(path)
                settings.accounts[agent] = newValue
                preferences.setProjectSettings(path, settings)
            }
        )
    }

    private func claudeFlagsBinding(for path: String) -> Binding<FlagSet> {
        Binding(
            get: {
                guard case .claude(let flags)? = preferences.projectSettings(path).options[.claude]
                else { return FlagSet() }
                return flags
            },
            set: { newValue in setOptions(.claude(newValue), for: .claude, path: path) }
        )
    }

    private func codexOptionsBinding(for path: String) -> Binding<CodexThreadOptions> {
        Binding(
            get: {
                guard case .codex(let opts)? = preferences.projectSettings(path).options[.codex]
                else { return CodexThreadOptions() }
                return opts
            },
            set: { newValue in setOptions(.codex(newValue), for: .codex, path: path) }
        )
    }

    /// An emptied override is a removal, not an empty override: persisting the empty value
    /// would keep the project listed forever with its badge hidden and "Remove Overrides"
    /// disabled, leaving no way to delete it. Shared by both agents' bindings.
    private func setOptions(_ options: AgentOptions, for agent: AgentID, path: String) {
        var settings = preferences.projectSettings(path)
        settings.options[agent] = options.isEmpty ? nil : options
        preferences.setProjectSettings(path, settings)
    }
}
