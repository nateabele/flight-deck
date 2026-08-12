import SwiftUI

/// Per-project overrides. The project list is the union of currently-open projects and
/// projects with a saved override — a `Repo` vanishes from `SessionStore` when its last
/// session closes, so open projects alone would lose overrides from view.
struct ProjectsSettingsTab: View {
    @ObservedObject var preferences: PreferencesStore
    @ObservedObject var sessions: SessionStore
    @State private var selected: String?

    private var paths: [String] {
        let open = sessions.repos.map(\.url.standardizedFileURL.path)
        return Array(Set(open).union(preferences.overriddenProjectPaths)).sorted()
    }

    var body: some View {
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
    }

    private func binding(for path: String) -> Binding<FlagSet> {
        Binding(
            get: { preferences.projectOverride(path) },
            set: { preferences.setProjectOverride(path, $0) }
        )
    }
}
