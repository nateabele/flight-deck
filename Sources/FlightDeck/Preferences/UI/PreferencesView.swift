import SwiftUI

struct PreferencesView: View {
    @ObservedObject var preferences: PreferencesStore
    @ObservedObject var sessions: SessionStore
    @ObservedObject var fleet: FleetService
    @ObservedObject var hosts: HostService
    @ObservedObject var hosting: HostingController
    @ObservedObject var routing: RoutingService
    let cloud: CloudSettingsContext

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

            HostsSettingsTab(hostService: hosts, infra: cloud.service)
                .tabItem { Label("Hosts", systemImage: "desktopcomputer.and.arrow.down") }
                .accessibilityIdentifier("prefs-hosts")
                .tag(PreferencesTab.hosts)

            HostingSettingsTab(controller: hosting)
                .tabItem { Label("Hosting", systemImage: "server.rack") }
                .accessibilityIdentifier("prefs-hosting")
                .tag(PreferencesTab.hosting)

            CloudSettingsTab(preferences: preferences, context: cloud)
                .tabItem { Label("Cloud", systemImage: "cloud") }
                .accessibilityIdentifier("prefs-cloud")
                .tag(PreferencesTab.cloud)

            FlightControlSettingsTab(preferences: preferences, sessions: sessions, routing: routing)
                .tabItem { Label("Flight Control", systemImage: "airplane") }
                // No `.accessibilityIdentifier` here: on a container SwiftUI/macOS stamps it over
                // every descendant, which renamed the section control, the project picker and the
                // scroll view to "prefs-flight-control" and hid `fc-section-picker` from XCUITest.
                .tag(PreferencesTab.flightControl)
        }
        .frame(width: 720, height: 560)
    }
}
