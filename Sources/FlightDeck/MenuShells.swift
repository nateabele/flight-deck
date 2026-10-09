import SwiftUI

/// Every `Commands` the main window installs, in one place so `MenuBarStabilityTests` and the
/// menu-bar harness (`scripts/test-menu-bar.sh`) install exactly the app's set.
///
/// **Each one is constant: none reads any state** (`AppKitMenuSlot` has the measurements). A
/// `Commands` that observes anything makes SwiftUI reconcile the main menu whenever it publishes,
/// whatever the output. The items whose state follows the window — New Session's agent rows,
/// View ▸ Inspector, Run, Tools — are AppKit items inside the shells below.
struct FlightDeckCommands: Commands {
    let store: SessionStore
    let preferences: PreferencesStore

    var body: some Commands {
        SessionCommands(store: store)
        EditCommands()
        FontSizeCommands(store: store, preferences: preferences)
        TabNavigationCommands(store: store)
        SearchCommands()
        InspectorMenuShell()
        // Tools before Run: the order the bar has always had (View, Tools, Run, Window).
        ToolsMenuShell()
        RunMenuShell()
        ShortcutOverlayCommands()
    }
}

/// A placeholder for a shell: SwiftUI builds no menu for an empty `CommandMenu`, so it gets one
/// item, which `AppKitMenuSlot` hides once the real items are in.
private struct ShellPlaceholder: View {
    var body: some View { Button("—") {}.disabled(true) }
}

/// The Tools menu, authored by SwiftUI so its reconciliation never removes it; the items are
/// `ToolsMenuController`'s.
struct ToolsMenuShell: Commands {
    static let title = "Tools"
    var body: some Commands {
        CommandMenu(Self.title) { ShellPlaceholder() }
    }
}

/// The Run menu (spec §4); the items are `RunMenuController`'s.
struct RunMenuShell: Commands {
    static let title = "Run"
    var body: some Commands {
        CommandMenu(Self.title) { ShellPlaceholder() }
    }
}

/// View ▸ Inspector, after the sidebar item; the items are `InspectorMenuController`'s.
struct InspectorMenuShell: Commands {
    static let title = "Inspector"
    var body: some Commands {
        CommandGroup(after: .sidebar) {
            Menu(Self.title) { ShellPlaceholder() }
        }
    }
}
