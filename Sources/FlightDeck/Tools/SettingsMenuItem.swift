import AppKit

/// Finds SwiftUI's own "Settings…" item in the application menu, so AppKit code can open the
/// Settings scene by driving the item SwiftUI actually installed.
///
/// **Why not `NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)`.** That
/// is the widely-repeated recipe, and on this macOS it is worse than not working: it returns
/// **true**. Something in the responder chain accepts the selector, so the call reports success
/// while no window ever appears — and any `showPreferencesWindow:` fallback guarded on that
/// return value never runs. "A responder accepted this" is not the same question as "Settings
/// opened", and the first one is the only one `sendAction` can answer.
///
/// Instrumenting the running app showed SwiftUI wires its Settings item to a private
/// `menuAction:` selector on a private `MenuItemCallback` target. Neither name is ours to
/// depend on — but the item itself is right there in the menu, already correctly wired, so the
/// reliable move is to send *its* action to *its* target rather than to guess at names.
enum SettingsMenuItem {
    /// Matched on the chord, not the title. The title is localized, and macOS 13 renamed it
    /// from "Preferences…" to "Settings…"; ⌘, is the part that has not moved.
    ///
    /// An item with no action is rejected: sending a nil action would be a silent no-op, which
    /// is the exact failure this type exists to end.
    static func locate(in appMenu: NSMenu) -> NSMenuItem? {
        appMenu.items.first { item in
            guard item.action != nil, item.keyEquivalent == "," else { return false }
            let chord = item.keyEquivalentModifierMask
                .intersection([.command, .control, .option, .shift])
            return chord == [.command]
        }
    }
}
