import SwiftUI

struct PreferencesView: View {
    @ObservedObject var preferences: PreferencesStore
    @ObservedObject var sessions: SessionStore
    @ObservedObject var fleet: FleetService

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
        }
        .frame(width: 720, height: 560)
    }
}
