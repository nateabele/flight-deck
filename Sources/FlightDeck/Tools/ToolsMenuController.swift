import AppKit

/// Builds and maintains the Tools menu.
///
/// **Why AppKit rather than a SwiftUI `Commands` group.** `SessionCommands` documents that
/// SwiftUI cannot vary a `.keyboardShortcut` at runtime, and works around it by giving each
/// agent position a statically chorded item. A user-recorded chord is dynamic by definition, so
/// that workaround does not extend here. `NSMenuItem.keyEquivalent` is a plain property.
///
/// **Why a menu at all, rather than a bare key monitor.** Three things come free: the chord
/// renders beside the tool's name, so the feature is discoverable; `MenuKeyEquivalents` routes
/// Ghostty's swallowed ⌘-combinations here with no change, because it walks the whole main menu
/// and names no specific shortcut; and validation gives the disabled state.
@MainActor
final class ToolsMenuController: NSObject, NSMenuItemValidation {
    private(set) var menu = NSMenu(title: "Tools")

    var tools: [ToolDefinition] = [] { didSet { rebuild() } }
    /// Whether a session is selected. A tool with no working directory must not run.
    var isEnabled: () -> Bool = { false }
    var run: (ToolDefinition) -> Void = { _ in }
    var openPreferences: () -> Void = {}

    override init() {
        super.init()
        // `autoenablesItems` stays at its default (on): every item here carries an explicit
        // `target`, so AppKit consults `validateMenuItem` on that target directly rather than
        // walking the responder chain. `validateMenuItem` is the single authority for enabling.
        rebuild()
    }

    /// Inserts the menu, replacing any copy already there.
    ///
    /// Idempotent because SwiftUI owns `NSApp.mainMenu` and may rebuild it, so this can run
    /// more than once. Placement is by title lookup rather than a fixed index for the same
    /// reason: the menu is populated asynchronously, so View may not exist yet.
    func install(in mainMenu: NSMenu) {
        for item in mainMenu.items where item.submenu?.title == "Tools" {
            mainMenu.removeItem(item)
        }
        let host = NSMenuItem()
        host.submenu = menu

        let afterView = mainMenu.items.firstIndex { $0.submenu?.title == "View" }.map { $0 + 1 }
        let beforeWindow = mainMenu.items.firstIndex { $0.submenu?.title == "Window" }
        mainMenu.insertItem(host, at: afterView ?? beforeWindow ?? mainMenu.items.count)
    }

    private func rebuild() {
        menu.removeAllItems()

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
            menu.addItem(item)
        }

        // Always present, even with no tools: deleting every tool must not leave a dead menu
        // with no route back to the pane that would restore one.
        menu.addItem(.separator())
        let configure = NSMenuItem(
            title: "Configure Tools…", action: #selector(configure(_:)), keyEquivalent: ""
        )
        configure.target = self
        menu.addItem(configure)
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
