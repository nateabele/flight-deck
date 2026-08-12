import SwiftUI

struct PreferencesView: View {
    @ObservedObject var preferences: PreferencesStore
    @ObservedObject var sessions: SessionStore

    var body: some View {
        TabView {
            ClaudeSettingsTab(preferences: preferences)
                .tabItem { Label("Claude", systemImage: "sparkles") }
                .accessibilityIdentifier("prefs-claude")

            ProjectsSettingsTab(preferences: preferences, sessions: sessions)
                .tabItem { Label("Projects", systemImage: "folder") }
                .accessibilityIdentifier("prefs-projects")

            ShellSettingsTab(preferences: preferences)
                .tabItem { Label("Shell & Environment", systemImage: "terminal") }
                .accessibilityIdentifier("prefs-shell")
        }
        .frame(width: 720, height: 560)
    }
}
