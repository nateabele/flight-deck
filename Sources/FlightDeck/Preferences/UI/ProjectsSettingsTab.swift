import SwiftUI

/// Per-project overrides. The project list is the union of currently-open projects and
/// projects with a saved override — an override outlives the project it belongs to, since
/// closing a project removes it from `SessionStore` entirely.
///
/// The detail pane is three sections: which agent (also the project's default, per
/// `ProjectSettings.defaultAgent`), which of that agent's accounts, and that agent's options.
/// The Agent picker doubles as both the default-agent setter AND the selector for what the
/// sections below edit — but a per-project override applies whenever that agent launches here
/// regardless of what the picker currently shows, so `hiddenOverrideSummary` names whichever
/// other agent still has one in force while it is off-screen.
struct ProjectsSettingsTab: View {
    @ObservedObject var preferences: PreferencesStore
    @ObservedObject var sessions: SessionStore
    @State private var selected: String?

    private var paths: [String] {
        let open = sessions.repos.map(\.url.standardizedFileURL.path)
        return Array(Set(open).union(preferences.configuredProjectPaths)).sorted()
    }

    var body: some View {
        VStack(spacing: 0) {
            NavigationSplitView {
                List(paths, id: \.self, selection: $selected) { path in
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
                .navigationSplitViewColumnWidth(min: 180, ideal: 220)
                .onChange(of: paths) { _, newPaths in
                    // Covers both "Remove Overrides" and reverting every override to empty
                    // (which also removes the record, see the option bindings below): either
                    // can drop the selected path from the list out from under the detail pane.
                    if let selected, !newPaths.contains(selected) { self.selected = nil }
                }
            } detail: {
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
            .padding(.horizontal, 12)
            .padding(.top, 8)

            Form {
                Section("Agent") {
                    Picker("Agent", selection: agentBinding(for: path)) {
                        Text("<Use global settings>").tag(AgentID?.none)
                        ForEach(AgentID.allCases, id: \.self) { agent in
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

                let accounts = preferences.preferences.accounts(for: selectedAgent)
                if accounts.count > 1 {
                    Section("Account") {
                        Picker("Account", selection: accountBinding(for: path, agent: selectedAgent)) {
                            Text("Default (\(accounts.first?.displayName ?? ""))").tag(UUID?.none)
                            ForEach(accounts) { account in
                                Text(account.displayName).tag(UUID?.some(account.id))
                            }
                        }
                        .labelsHidden()
                        .accessibilityIdentifier("project-account-picker")
                    }
                }
            }
            .formStyle(.grouped)
            .frame(maxHeight: 220)

            Group {
                switch selectedAgent {
                case .codex:
                    CodexOptionsForm(
                        preferences: preferences,
                        projectOverride: codexOptionsBinding(for: path)
                    )
                default:
                    FlagEditor(
                        flags: claudeFlagsBinding(for: path),
                        inherited: globalClaudeFlags,
                        lockedPrefix: ClaudeOptionsPane.placeholderPrefix
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

    private func accountBinding(for path: String, agent: AgentID) -> Binding<UUID?> {
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
