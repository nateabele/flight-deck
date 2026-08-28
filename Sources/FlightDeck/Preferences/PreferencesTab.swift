import Foundation

/// A pane of the Settings window.
///
/// Exists so code outside the view can ask for a particular pane — "Configure Tools…" in the
/// Tools menu promises to take you to Tools, and without a tag to select there is no way to
/// keep that promise. `PreferencesView`'s `TabView` binds its selection to these.
///
/// Not `Codable` and deliberately not part of `Preferences`: which pane is showing is
/// transient UI state. Persisting it would rewrite `preferences.v1` on every tab click and
/// reopen Settings days later on whatever pane was last touched.
enum PreferencesTab: Hashable, CaseIterable {
    case agents
    case projects
    case shell
    case tools
    case devices
}
