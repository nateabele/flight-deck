import SwiftUI

struct PreferencesView: View {
    @ObservedObject var preferences: PreferencesStore
    @ObservedObject var sessions: SessionStore
    @ObservedObject var fleet: FleetService

    var body: some View {
        TabView {
            AgentsSettingsTab(preferences: preferences, sessions: sessions)
                .tabItem { Label("Agents", systemImage: "person.2") }
                .accessibilityIdentifier("prefs-agents")

            ProjectsSettingsTab(preferences: preferences, sessions: sessions)
                .tabItem { Label("Projects", systemImage: "folder") }
                .accessibilityIdentifier("prefs-projects")

            ShellSettingsTab(preferences: preferences)
                .tabItem { Label("Shell & Environment", systemImage: "terminal") }
                .accessibilityIdentifier("prefs-shell")

            ToolsSettingsTab(preferences: preferences, sessions: sessions)
                .tabItem { Label("Tools", systemImage: "wrench.and.screwdriver") }
                .accessibilityIdentifier("prefs-tools")

            DevicesSettingsTab(preferences: preferences, service: fleet)
                .tabItem { Label("Devices", systemImage: "iphone.and.arrow.forward") }
                .accessibilityIdentifier("prefs-devices")
        }
        .frame(width: 720, height: 560)
    }
}
