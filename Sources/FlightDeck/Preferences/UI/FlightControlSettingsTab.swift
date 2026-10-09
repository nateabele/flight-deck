import IntakeKit
import SwiftUI

/// Settings → Flight Control: Routing, Task Kinds, Capability Index and Capacity. The sections are
/// a segmented control rather than a nested `TabView`: a tab strip inside the Settings tab strip
/// reads as two windows' chrome.
struct FlightControlSettingsTab: View {
    enum Section: String, CaseIterable, Identifiable {
        case routing = "Routing"
        case kinds = "Task Kinds"
        case capabilityIndex = "Capability Index"
        case capacity = "Capacity"
        var id: String { rawValue }
        /// What the UI tests name a section by. A segmented `Picker`'s segments are not separate
        /// views, so they cannot carry these as accessibility identifiers; the UI tests'
        /// `selectFlightControlSection` maps each one to its segment's title instead.
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
            HStack(spacing: 12) {
                Picker("Section", selection: $section) {
                    ForEach(Section.allCases) { s in Text(s.rawValue).tag(s) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .accessibilityIdentifier("fc-section-picker")
                Spacer(minLength: 12)
                Picker("Project", selection: $project) {
                    Text("No project").tag(String?.none)
                    ForEach(paths, id: \.self) { p in
                        Label(URL(fileURLWithPath: p).lastPathComponent, systemImage: "folder").tag(String?.some(p))
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 220)
                .help("The project whose rules and task kinds are shown")
                .accessibilityLabel("Project")
                .accessibilityIdentifier("fc-project-picker")
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)
            .padding(.bottom, section == .routing ? 4 : 12)
            // Routing is a grouped form whose inset sections separate it from the bar; the other
            // panes run edge to edge and need the line.
            if section != .routing { Divider() }
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
                        CapabilityIndexPane(service: index, preferences: preferences)
                    } else {
                        Text("The capability index is not running in this window.")
                            .foregroundStyle(.secondary).padding()
                    }
                case .capacity:
                    CapacityPane(preferences: preferences, usage: UsageService.shared,
                                 localAgents: CapacityPane.defaultLocalAgents())
                }
            }
            .id(project)
        }
        .onAppear {
            if project == nil { project = routing.fixtureProjects?.first ?? paths.first }
        }
    }
}
