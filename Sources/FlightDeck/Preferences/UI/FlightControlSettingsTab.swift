import IntakeKit
import SwiftUI

/// Settings → Flight Control. L3-R's Routing and Task kinds live here; L3-I's Capability index
/// and L3-U's Capacity join them at integration. Sections are buttons along the top rather than
/// a nested `TabView`: a tab strip inside the Settings tab strip reads as two windows' chrome.
struct FlightControlSettingsTab: View {
    enum Section: String, CaseIterable, Identifiable {
        case routing = "Routing"
        case kinds = "Task kinds"
        var id: String { rawValue }
        /// What `RoutingUITests` clicks.
        var identifier: String { self == .routing ? "fc-section-routing" : "fc-section-kinds" }
    }

    @ObservedObject var preferences: PreferencesStore
    @ObservedObject var sessions: SessionStore
    @ObservedObject var routing: RoutingService
    @State private var section: Section = .routing
    @State private var project: String?

    /// Open projects (standardized the way the Projects pane spells them) plus the fixture's.
    private var paths: [String] {
        let open = sessions.repos.map(\.url.standardizedFileURL.path)
        return Array(Set(open).union(routing.fixtureProjects ?? [])).sorted()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                ForEach(Section.allCases) { s in
                    Button(s.rawValue) { section = s }
                        .buttonStyle(.bordered)
                        .tint(section == s ? Color.accentColor : nil)
                        .accessibilityIdentifier(s.identifier)
                }
                Spacer()
                Picker("Project", selection: $project) {
                    Text("No project").tag(String?.none)
                    ForEach(paths, id: \.self) { p in
                        Text(URL(fileURLWithPath: p).lastPathComponent).tag(String?.some(p))
                    }
                }
                .frame(maxWidth: 260)
                .accessibilityIdentifier("fc-project-picker")
            }
            .padding(12)
            Divider()
            // Identity per project: both panes keep @State (selection, rename text, weights,
            // drafts) that SwiftUI would otherwise carry across a project switch. A same-id kind
            // in the new project never fires onChange(of: selection), so Rename/Re-weight would
            // write the previous project's name/weights into it.
            Group {
                switch section {
                case .routing: FlightControlRoutingPane(routing: routing, preferences: preferences, project: project)
                case .kinds: TaskKindsPane(routing: routing, project: project)
                }
            }
            .id(project)
        }
        .onAppear {
            if project == nil { project = routing.fixtureProjects?.first ?? paths.first }
        }
    }
}
