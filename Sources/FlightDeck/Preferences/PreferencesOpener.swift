import AppKit

/// Opens the Settings window on a chosen pane — the action behind "Configure Tools…" in the
/// Tools menu, the Tools overlay's ⌘-revealed sprocket, and "Configure…" on a project row.
///
/// One implementation rather than one per call site: "the same thing as the menu item" is a
/// requirement, not a coincidence, and the sequencing below is why it cannot simply be
/// re-typed wherever Settings needs opening.
@MainActor
enum PreferencesOpener {
    /// Points the Settings window at a pane, and optionally at one project inside the Projects
    /// pane, without opening anything.
    ///
    /// Separate from `open` so the part with the interesting behaviour is testable: `open`'s
    /// second half drives the real main menu through `NSApp`, which a unit test has no business
    /// standing up.
    static func select(
        _ preferences: PreferencesStore?,
        tab: PreferencesTab,
        project: String? = nil
    ) {
        guard let preferences else { return }
        preferences.selectedTab = tab
        // Only ever set, never cleared: opening Settings on some other pane must not throw away
        // the project the Projects pane was last pointed at.
        if let project {
            preferences.selectedProjectPath = URL(fileURLWithPath: project).standardizedFileURL.path
        }
    }

    static func open(_ preferences: PreferencesStore?, tab: PreferencesTab, project: String? = nil) {
        // Choose the pane BEFORE the window opens: on a first open the view is built from
        // this value, and on a later one the published change moves the live selection.
        // Setting it afterwards would flash the previous pane.
        select(preferences, tab: tab, project: project)

        // Drive SwiftUI's own Settings item rather than guessing a selector. See
        // `SettingsMenuItem`: `showSettingsWindow:` returns true on this macOS and opens
        // nothing, so a fallback guarded on its return value can never fire.
        if let appMenu = NSApp.mainMenu?.items.first?.submenu,
           let item = SettingsMenuItem.locate(in: appMenu),
           let action = item.action {
            NSApp.sendAction(action, to: item.target, from: item)
            return
        }
        // Only reached if SwiftUI's item is missing entirely — a shape this app has never
        // been observed in, but a wrong-looking window beats a dead menu item.
        _ = NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }
}
