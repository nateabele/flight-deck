import IntakeKit
import SwiftUI

/// Settings → Flight Control: Routing, Task kinds, Capability index and Capacity. Sections are buttons along the top rather than
/// a nested `TabView`: a tab strip inside the Settings tab strip reads as two windows' chrome.
struct FlightControlSettingsTab: View {
    enum Section: String, CaseIterable, Identifiable {
        case routing = "Routing"
        case kinds = "Task kinds"
        case capabilityIndex = "Capability index"
        case capacity = "Capacity"
        var id: String { rawValue }
        /// What the UI tests click.
        var identifier: String {
            switch self {
            case .routing: "fc-section-routing"
            case .kinds: "fc-section-kinds"
            case .capabilityIndex: "fc-section-index"
            case .capacity: "fc-section-capacity"
            }
        }
    }

    @ObservedObject var preferences: PreferencesStore
    @ObservedObject var sessions: SessionStore
    @ObservedObject var routing: RoutingService
    @State private var section: Section
    @State private var project: String?

    init(preferences: PreferencesStore, sessions: SessionStore, routing: RoutingService,
         initialSection: Section = .routing) {
        self.preferences = preferences; self.sessions = sessions; self.routing = routing
        _section = State(initialValue: initialSection)
    }

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
                case .capabilityIndex:
                    if let index = sessions.capabilityIndexService {
                        CapabilityIndexPane(service: index)
                    } else {
                        Text("The capability index is not running in this window.")
                            .foregroundStyle(.secondary).padding()
                    }
                case .capacity:
                    CapacityPane(preferences: preferences, usage: UsageService.shared,
                                 localHarnesses: CapacityPane.defaultLocalHarnesses())
                }
            }
            .id(project)
        }
        .onAppear {
            if project == nil { project = routing.fixtureProjects?.first ?? paths.first }
        }
    }
}
