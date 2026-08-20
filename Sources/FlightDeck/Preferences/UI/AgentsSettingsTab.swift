import SwiftUI

/// Replaces the old single-agent Claude tab. The list on the left is both the agent
/// registry and the shortcut binding — row 1 is ⌘N, row 2 ⌘⇧N, row 3 ⌘⇧⌥N — so the shortcut
/// is shown inline on each row rather than hidden in a help string. Dragging a row is what
/// rebinds ⌘N: see `Preferences.moveAgents` and `NewSessionAffordance`.
struct AgentsSettingsTab: View {
    @ObservedObject var preferences: PreferencesStore
    @ObservedObject var sessions: SessionStore
    @State private var selection: AgentID?

    var body: some View {
        HSplitView {
            List(selection: $selection) {
                ForEach(preferences.preferences.agents, id: \.id) { settings in
                    HStack {
                        Text(settings.id.displayName)
                        Spacer()
                        Text(shortcut(for: settings.id))
                            .foregroundStyle(.secondary)
                            .monospaced()
                    }
                    .tag(settings.id)
                }
                .onMove { offsets, destination in
                    preferences.preferences.moveAgents(fromOffsets: offsets, toOffset: destination)
                }
            }
            .frame(minWidth: 160)

            VStack(alignment: .leading, spacing: 0) {
                let agent = selection ?? preferences.preferences.agents.first?.id ?? .claude
                Group {
                    switch agent {
                    case .codex: CodexOptionsForm(preferences: preferences)
                    default:     ClaudeOptionsPane(preferences: preferences)
                    }
                }
                .frame(maxHeight: .infinity)

                Divider()

                AccountsSection(preferences: preferences, sessions: sessions, agent: agent)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
            }
            .frame(minWidth: 380)
        }
    }

    private func shortcut(for agent: AgentID) -> String {
        NewSessionAffordance.slots(for: preferences.preferences.agents)
            .first { $0.agent == agent }?.shortcutDisplay ?? ""
    }
}

/// Global defaults: the flags every new session starts with, in every project.
///
/// Formerly `ClaudeSettingsTab`, the app's only Preferences tab before agent adapters — this
/// is that same body, moved under the Agents list's claude row. Bound to the claude row's
/// `AgentOptions` in `preferences.agents`, not `globalFlags`: `SessionStore.options(for:project:)`
/// resolves a launch's flags via `PreferencesStore.resolvedOptions(for:project:)`, which reads
/// that row, and `globalFlags` survives only as a decode-only legacy field.
struct ClaudeOptionsPane: View {
    @ObservedObject var preferences: PreferencesStore

    /// Reads and writes the claude row's flags within `preferences.agents`, wherever that row
    /// currently sits — the list's order is the shortcut binding, not a storage index, so this
    /// looks the row up by id rather than assuming a position. Mirrors `CodexOptionsForm.options`.
    private var flags: Binding<FlagSet> {
        Binding(
            get: {
                guard case .claude(let flags)? = preferences.preferences.agents
                    .first(where: { $0.id == .claude })?.options
                else { return FlagSet() }
                return flags
            },
            set: { newValue in
                guard let index = preferences.preferences.agents.firstIndex(where: { $0.id == .claude })
                else { return }
                preferences.preferences.agents[index].options = .claude(newValue)
            }
        )
    }

    var body: some View {
        FlagEditor(
            flags: flags,
            inherited: nil,
            lockedPrefix: Self.placeholderPrefix,
            header: {
                AnyView(
                    Section("Startup") {
                        Toggle(
                            "Auto-resume running sessions on restart",
                            isOn: Binding(
                                get: { preferences.autoResumesRunningSessions },
                                set: { preferences.autoResumesRunningSessions = $0 }
                            )
                        )
                        .accessibilityIdentifier("prefs-auto-resume")
                        // States the busy/shell rule in the user's terms: "running" is not
                        // self-evident from the label, and the exclusions are the surprising
                        // half.
                        Text("Sessions that were working when Flight Deck last quit are asked to continue once they have resumed. Sessions that were idle, or waiting on you, are left alone.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                )
            }
        )
    }

    /// There is no real session in the global tab, so the immutable prefix shows what
    /// Flight Deck will substitute rather than a concrete id and name. Deliberately not
    /// generated by calling `ClaudeSession.lockedPrefix` with sentinel values — that would
    /// route the placeholder text through `sanitizedName`/`shellQuoted` and render as
    /// `--name '⟨session title⟩'`, which is worse. Nothing else keeps this in step with
    /// `lockedPrefix`'s actual flag sequence, so
    /// `ClaudeSessionTests.testPlaceholderPrefixMatchesTheRealPrefixShape` pins the shape.
    static let placeholderPrefix = "claude --session-id ⟨generated⟩ --name ⟨session title⟩"
}
