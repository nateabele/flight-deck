import SwiftUI

/// Per-project overrides. The project list is the union of currently-open projects and
/// projects with a saved override — an override outlives the project it belongs to, since
/// closing a project removes it from `SessionStore` entirely.
struct ProjectsSettingsTab: View {
    @ObservedObject var preferences: PreferencesStore
    @ObservedObject var sessions: SessionStore
    @State private var selected: String?

    private var paths: [String] {
        let open = sessions.repos.map(\.url.standardizedFileURL.path)
        return Array(Set(open).union(preferences.overriddenProjectPaths)).sorted()
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
                    .badge(preferences.projectOverride(path).isEmpty ? nil : Text("override"))
                    .tag(path)
                }
                .navigationSplitViewColumnWidth(min: 180, ideal: 220)
                .onChange(of: paths) { _, newPaths in
                    // Covers both "Remove Override" and reverting a project's flags to empty
                    // (which also removes it, see `binding(for:)`): either can drop the
                    // selected path from the list out from under the detail pane.
                    if let selected, !newPaths.contains(selected) { self.selected = nil }
                }
            } detail: {
                if let selected {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack {
                            Text(selected).font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button("Remove Override") {
                                preferences.removeProjectOverride(selected)
                            }
                            .disabled(preferences.projectOverride(selected).isEmpty)
                        }
                        .padding(.horizontal, 12)
                        .padding(.top, 8)

                        FlagEditor(
                            flags: binding(for: selected),
                            inherited: preferences.preferences.globalFlags,
                            lockedPrefix: ClaudeSettingsTab.placeholderPrefix
                        )
                        .id(selected)
                    }
                } else {
                    ContentUnavailableView(
                        "No Project Selected",
                        systemImage: "folder",
                        description: Text("Select a project to override its Claude options.")
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

    private func binding(for path: String) -> Binding<FlagSet> {
        Binding(
            get: { preferences.projectOverride(path) },
            set: {
                // An emptied override is a removal, not an empty override: persisting the
                // empty set would keep the project listed forever with its badge hidden
                // and its Remove button disabled, leaving no way to delete it.
                $0.isEmpty ? preferences.removeProjectOverride(path)
                           : preferences.setProjectOverride(path, $0)
            }
        )
    }
}
