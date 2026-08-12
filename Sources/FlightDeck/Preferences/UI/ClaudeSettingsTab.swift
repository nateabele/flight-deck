import SwiftUI

/// Global defaults: the flags every new session starts with, in every project.
struct ClaudeSettingsTab: View {
    @ObservedObject var preferences: PreferencesStore

    var body: some View {
        FlagEditor(
            flags: $preferences.preferences.globalFlags,
            inherited: nil,
            lockedPrefix: Self.placeholderPrefix
        )
    }

    /// There is no real session in the global tab, so the immutable prefix shows what
    /// Flight Deck will substitute rather than a concrete id and name.
    static let placeholderPrefix = "claude --session-id ⟨generated⟩ --name ⟨session title⟩"
}
