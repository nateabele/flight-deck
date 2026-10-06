import SwiftUI

struct PreferencesView: View {
    @ObservedObject var preferences: PreferencesStore
    @ObservedObject var sessions: SessionStore
    @ObservedObject var fleet: FleetService
    @ObservedObject var hosts: HostService
    @ObservedObject var hosting: HostingController
    @ObservedObject var routing: RoutingService

    var body: some View {
        // Bound rather than unbound, and every pane tagged: without a selection binding there
        // is no way for "Configure Tools…" to land on Tools, which is the promise its title
        // makes. The tags are what the binding matches on.
        TabView(selection: $preferences.selectedTab) {
            AgentsSettingsTab(preferences: preferences, sessions: sessions)
                .tabItem { Label("Agents", systemImage: "person.2") }
                .accessibilityIdentifier("prefs-agents")
                .tag(PreferencesTab.agents)

            ProjectsSettingsTab(preferences: preferences, sessions: sessions)
                .tabItem { Label("Projects", systemImage: "folder") }
                .accessibilityIdentifier("prefs-projects")
                .tag(PreferencesTab.projects)

            ShellSettingsTab(preferences: preferences)
                .tabItem { Label("Shell & Environment", systemImage: "terminal") }
                .accessibilityIdentifier("prefs-shell")
                .tag(PreferencesTab.shell)

            ToolsSettingsTab(preferences: preferences, sessions: sessions)
                .tabItem { Label("Tools", systemImage: "wrench.and.screwdriver") }
                .accessibilityIdentifier("prefs-tools")
                .tag(PreferencesTab.tools)

            DevicesSettingsTab(preferences: preferences, service: fleet)
                .tabItem { Label("Devices", systemImage: "iphone.and.arrow.forward") }
                .accessibilityIdentifier("prefs-devices")
                .tag(PreferencesTab.devices)

            HostsSettingsTab(hostService: hosts)
                .tabItem { Label("Hosts", systemImage: "desktopcomputer.and.arrow.down") }
                .accessibilityIdentifier("prefs-hosts")
                .tag(PreferencesTab.hosts)

            HostingSettingsTab(controller: hosting)
                .tabItem { Label("Hosting", systemImage: "server.rack") }
                .accessibilityIdentifier("prefs-hosting")
                .tag(PreferencesTab.hosting)

            FlightControlSettingsTab(preferences: preferences, sessions: sessions, routing: routing)
                .tabItem { Label("Flight Control", systemImage: "airplane") }
                // No `.accessibilityIdentifier` here: on a container SwiftUI/macOS stamps it over
                // every descendant, which renamed the section buttons, the project picker and the
                // scroll view to "prefs-flight-control" and hid `fc-section-routing` from XCUITest.
                .tag(PreferencesTab.flightControl)
            CapabilityIndexSettingsTab(index: sessions.capabilityIndexService)
                .tabItem { Label("Capability Index", systemImage: "chart.bar.xaxis") }
                .tag(PreferencesTab.capabilityIndex)

            // No container-level accessibilityIdentifier on this tab: SwiftUI stamps it onto every
            // child and hides the leaf controls' own identifiers from the UI test.
            CapacityPane(preferences: preferences, usage: UsageService.shared,
                         localHarnesses: CapacityPane.defaultLocalHarnesses())
                .tabItem { Label("Capacity", systemImage: "gauge.with.dots.needle.33percent") }
                .tag(PreferencesTab.capacity)
        }
        .frame(width: 720, height: 560)
    }
}
