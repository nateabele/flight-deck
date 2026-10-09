import AppKit

/// Builds and maintains the Tools menu's items. The menu itself is a constant SwiftUI shell
/// (`ToolsMenuShell`), so SwiftUI authored it and never removes it; these items live inside it
/// (`AppKitMenuSlot`). It used to be an AppKit top-level menu, which every SwiftUI menu
/// reconciliation removed and this put back a turn later — the Tools menu blinking out and in
/// on tab and inspector-mode switches (2026-10-09).
///
/// **Why AppKit items rather than SwiftUI buttons.** SwiftUI cannot vary a `.keyboardShortcut`
/// at runtime, and a user-recorded chord is dynamic by definition. `NSMenuItem.keyEquivalent`
/// is a plain property.
///
/// **Why a menu at all, rather than a bare key monitor.** Three things come free: the chord
/// renders beside the tool's name, so the feature is discoverable; `MenuKeyEquivalents` routes
/// Ghostty's swallowed ⌘-combinations here with no change, because it walks the whole main menu
/// and names no specific shortcut; and validation gives the disabled state.
@MainActor
final class ToolsMenuController: NSObject, NSMenuItemValidation {
    /// Holds the items until `install` moves them into the shell — and is what a test reads.
    private let staging = NSMenu(title: "Tools")
    /// The menu the items are in: the shell once installed, `staging` before.
    var menu: NSMenu { slot.host ?? staging }
    private(set) var items: [NSMenuItem] = []

    var tools: [ToolDefinition] = [] { didSet { rebuild() } }
    /// Whether a session is selected. A tool with no working directory must not run.
    var isEnabled: () -> Bool = { false }
    var run: (ToolDefinition) -> Void = { _ in }
    var openPreferences: () -> Void = {}

    /// First in the shell, the placeholder SwiftUI needed to build the menu hidden behind them.
    private let slot = AppKitMenuSlot(path: [ToolsMenuShell.title], hidesOthers: true)

    override init() {
        super.init()
        // `autoenablesItems` stays at its default (on): every item here carries an explicit
        // `target`, so AppKit consults `validateMenuItem` on that target directly rather than
        // walking the responder chain. `validateMenuItem` is the single authority for enabling.
        rebuild()
    }

    /// Moves the items into the SwiftUI shell and keeps them there. Idempotent: SwiftUI builds
    /// the main menu asynchronously, so this runs more than once. The prune it used to undo can
    /// no longer happen to the menu (SwiftUI authored it); `AppKitMenuSlot` still re-checks the
    /// items on every change to the bar, as a backstop.
    func install(in mainMenu: NSMenu) {
        slot.install(in: mainMenu)
    }

    private func rebuild() {
        var built: [NSMenuItem] = []

        for tool in tools {
            let item = NSMenuItem(
                title: tool.name,
                action: #selector(runTool(_:)),
                keyEquivalent: tool.shortcut?.key ?? ""
            )
            item.keyEquivalentModifierMask = tool.shortcut?.modifierFlags ?? []
            item.image = NSImage(systemSymbolName: tool.symbol, accessibilityDescription: nil)
            item.representedObject = tool
            item.target = self
            built.append(item)
        }

        // Always present, even with no tools: deleting every tool must not leave a dead menu
        // with no route back to the pane that would restore one.
        built.append(.separator())
        let configure = NSMenuItem(
            title: "Configure Tools…", action: #selector(configure(_:)), keyEquivalent: ""
        )
        configure.target = self
        built.append(configure)
        items = built
        if slot.host == nil {
            staging.removeAllItems()
            for item in built { staging.addItem(item) }
        }
        slot.setItems(built)
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard item.action == #selector(runTool(_:)) else { return true }
        return isEnabled()
    }

    @objc private func runTool(_ sender: NSMenuItem) {
        guard let tool = sender.representedObject as? ToolDefinition else { return }
        run(tool)
    }

    @objc private func configure(_ sender: NSMenuItem) {
        openPreferences()
    }
}
