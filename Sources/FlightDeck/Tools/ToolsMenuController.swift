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

    /// The menu this controller was installed into, so a prune can be undone. Weak: the
    /// controller must not keep the main menu alive, and a released menu simply stops healing.
    private weak var hostMenu: NSMenu?
    private var pruneObserver: NSObjectProtocol?

    /// Inserts the menu, replacing any copy already there, and keeps it inserted.
    ///
    /// Idempotent because SwiftUI owns `NSApp.mainMenu` and may rebuild it, so this can run
    /// more than once. Placement is by title lookup rather than a fixed index for the same
    /// reason: the menu is populated asynchronously, so View may not exist yet.
    ///
    /// **Why this also has to survive being removed.** Installing once is not enough, and this
    /// was measured in the running app rather than guessed. Insertion at
    /// `applicationDidFinishLaunching` succeeds — the item lands correctly between View and
    /// Window — and SwiftUI's one-time main-menu reconciliation then *removes* it again from
    /// that same `NSMenu` instance, because it prunes items it did not author. The user-visible
    /// result was that ⌘O reached no menu item at all, fell through to the terminal, and
    /// arrived in the running agent's prompt as a literal "o".
    ///
    /// The prune posts `NSMenuDidRemoveItemNotification`, which is what makes this fixable
    /// without guessing a delay long enough to outlast SwiftUI. A delay would also not survive
    /// a *later* reconciliation — SwiftUI rebuilds its commands when observed state changes,
    /// and `SessionCommands` observes preferences, so editing a tool could prune the menu again.
    func install(in mainMenu: NSMenu) {
        hostMenu = mainMenu
        insert(into: mainMenu)

        guard pruneObserver == nil else { return }
        pruneObserver = NotificationCenter.default.addObserver(
            forName: NSMenu.didRemoveItemNotification, object: mainMenu, queue: .main
        ) { [weak self] _ in
            // Hop a turn before touching the menu: this fires *during* the removal, and
            // mutating a menu inside its own change notification is not safe. The hop is also
            // what lets `insert(into:)`'s own removal settle before we look.
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.reinsertIfPruned() }
            }
        }
    }

    /// Puts the menu back only if it is actually gone. Guarding on absence is what keeps
    /// `insert(into:)`'s own remove-then-insert from recursing into a second Tools menu.
    private func reinsertIfPruned() {
        guard let mainMenu = hostMenu else { return }
        guard !mainMenu.items.contains(where: { $0.submenu === menu }) else { return }
        insert(into: mainMenu)
    }

    private func insert(into mainMenu: NSMenu) {
        for item in mainMenu.items where item.submenu?.title == "Tools" {
            mainMenu.removeItem(item)
        }
        let host = NSMenuItem()
        host.submenu = menu

        let afterView = mainMenu.items.firstIndex { $0.submenu?.title == "View" }.map { $0 + 1 }
        let beforeWindow = mainMenu.items.firstIndex { $0.submenu?.title == "Window" }
        mainMenu.insertItem(host, at: afterView ?? beforeWindow ?? mainMenu.items.count)
    }

    deinit {
        if let pruneObserver { NotificationCenter.default.removeObserver(pruneObserver) }
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
