import AppKit
import SwiftUI

/// What View ▸ Inspector acts on: the plan on screen, its modes, and the one showing. `mode` is
/// read when the menu validates, not when the pane renders, so a mode switch changes nothing
/// that has to be republished anywhere.
struct InspectorModeActions {
    var intakeID: UUID
    var modes: [DetailLayout.InspectorMode]
    var mode: () -> DetailLayout.InspectorMode
    /// Switches to the mode and opens the column.
    var select: (DetailLayout.InspectorMode) -> Void
}

/// Which plan pane each window shows, for a menu AppKit owns (`InspectorMenuController`). Fed by
/// `PaneMenuAnchor`, a view in the pane; read only when the menu validates or an item fires.
///
/// **Why not a `@FocusedValue` read by a SwiftUI `Commands`,** which is what the inspector items
/// were. Every change to a `Commands` body's output makes SwiftUI reconcile the main menu, and
/// that reconciliation removes the menus it didn't author — the Tools menu
/// (`ToolsMenuController`) — which heal back a turn later. With the mode and the pane's presence
/// in a focused value, each Notes/Rounds click and each switch between a plan and another tab
/// rebuilt the menu bar: the Tools menu blinked out and back (the maintainer, 2026-10-09). Measured in a
/// standalone SwiftUI app with a Tools menu inserted the same way: the mode driving a `Toggle` in
/// a `CommandGroup` re-evaluated the commands and pruned the Tools menu on 10 of 10 mode switches
/// and 10 of 10 plan/terminal switches (a focused value, macOS 15; an observed object, macOS 26);
/// these AppKit items, validated on demand, on 0 of 10 mode switches.
@MainActor
final class PaneMenuRegistry<Value> {
    private struct Entry {
        weak var anchor: NSView?
        var value: Value
    }

    /// In registration order: a pane appearing while the old one is still being torn down (a
    /// switch between two plans) is the newer, and wins.
    private var entries: [ObjectIdentifier: Entry] = [:]
    private var order: [ObjectIdentifier] = []

    nonisolated init() {}

    func register(_ value: Value, anchor: NSView) {
        let key = ObjectIdentifier(anchor)
        if entries[key] == nil { order.append(key) }
        entries[key] = Entry(anchor: anchor, value: value)
    }

    func unregister(anchor: NSView) {
        let key = ObjectIdentifier(anchor)
        entries[key] = nil
        order.removeAll { $0 == key }
    }

    /// The pane in `window`; nil when that window shows none, which disables the items — and a
    /// disabled item's chord falls through.
    func value(in window: NSWindow?) -> Value? {
        guard let window else { return nil }
        for key in order.reversed() {
            guard let entry = entries[key], let anchor = entry.anchor else { continue }
            if anchor.window === window { return entry.value }
        }
        return nil
    }

    /// The window the menu acts on, as a focused scene value's was: the key window, else the main.
    var current: Value? { value(in: NSApp.keyWindow ?? NSApp.mainWindow) }
}

enum PaneMenus {
    /// View ▸ Inspector's.
    static let inspector = PaneMenuRegistry<InspectorModeActions>()
}

/// Puts a pane's menu value in a `PaneMenuRegistry` for as long as the pane is in a window.
/// Nothing here publishes: the registry is a plain table the menu reads on demand, so a new value
/// (a mode switch, a re-render) costs one dictionary write and rebuilds nothing.
struct PaneMenuAnchor<Value>: NSViewRepresentable {
    let registry: PaneMenuRegistry<Value>
    let value: Value

    func makeNSView(context: Context) -> AnchorView {
        let view = AnchorView()
        view.registry = registry
        view.value = value
        return view
    }

    func updateNSView(_ view: AnchorView, context: Context) {
        view.registry = registry
        view.value = value
    }

    static func dismantleNSView(_ view: AnchorView, coordinator: ()) {
        view.registry?.unregister(anchor: view)
    }

    final class AnchorView: NSView {
        weak var registry: PaneMenuRegistry<Value>?
        var value: Value? { didSet { sync() } }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            sync()
        }

        /// Registered only while in a window: a pane SwiftUI keeps off screen must not claim
        /// the menu for a window that shows something else.
        private func sync() {
            guard let registry else { return }
            if window != nil, let value { registry.register(value, anchor: self) } else { registry.unregister(anchor: self) }
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// View ▸ Inspector ▸ Notes ⌥⌘1 / Rounds ⌥⌘2 — Xcode's inspector-tab chords, and the
/// Keynote/Pages place for them. Each item shows the column on its mode, checked while it is
/// the one showing; ⌥⌘I still only shows and hides the column.
///
/// **AppKit, not a SwiftUI `Commands`.** Enablement and the checkmark come from
/// `validateMenuItem`, which AppKit asks when the menu opens and before a chord fires, so a mode
/// or tab switch rebuilds nothing and SwiftUI never reconciles the menu bar over it
/// (`PaneMenuRegistry` has the measurement).
///
/// **The chords, checked against Ghostty.** libghostty's macOS defaults
/// (`vendor/ghostty/src/config/Config.zig`) bind ⌘1–⌘8 (`goto_tab`) and ⌘9 (`last_tab`) with
/// `.super` alone, and nothing on ⌥⌘ plus a digit, so these fall through a focused surface to
/// the menu (`MenuKeyEquivalents`) with no unbind in `GhosttyDefaults.conf`. They also don't
/// reach a terminal at all while it has focus: no intake pane is on screen then, so the items
/// are disabled, and a disabled item never claims its key.
@MainActor
final class InspectorMenuController: NSObject, NSMenuItemValidation {
    let menu = NSMenu(title: "Inspector")
    /// The item in the View menu that holds `menu`.
    let hostItem = NSMenuItem(title: "Inspector", action: nil, keyEquivalent: "")
    private let registry: PaneMenuRegistry<InspectorModeActions>
    /// The window the items act on; the key window, else the main one. A seam for tests, which
    /// run with no key window.
    var window: () -> NSWindow? = { NSApp.keyWindow ?? NSApp.mainWindow }
    private weak var mainMenu: NSMenu?
    private var observers: [NSObjectProtocol] = []

    init(registry: PaneMenuRegistry<InspectorModeActions> = PaneMenus.inspector) {
        self.registry = registry
        super.init()
        for mode in DetailLayout.InspectorMode.allCases {
            let item = NSMenuItem(title: mode.title, action: #selector(select(_:)), keyEquivalent: String(mode.shortcut))
            item.keyEquivalentModifierMask = [.command, .option]
            item.representedObject = mode.rawValue
            item.target = self
            menu.addItem(item)
        }
        hostItem.submenu = menu
    }

    /// Puts the submenu in View and keeps it there. SwiftUI owns the main menu and prunes items
    /// it didn't author whenever it reconciles (`ToolsMenuController.install`), and it may hand
    /// View a fresh `NSMenu` while doing so — so any item removed from the bar or from View is
    /// answered, a turn later, by putting this back if it is gone.
    func install(in mainMenu: NSMenu) {
        self.mainMenu = mainMenu
        heal()
        guard observers.isEmpty else { return }
        for name in [NSMenu.didRemoveItemNotification, NSMenu.didAddItemNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                // Hop a turn: this fires during SwiftUI's mutation, and changing a menu inside its
                // own change notification is not safe.
                let changed = note.object as AnyObject?
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self, let mainMenu = self.mainMenu else { return }
                        // Only the bar and View concern us; every other menu's churn is ignored.
                        guard changed === mainMenu || changed === self.viewMenu(in: mainMenu) else { return }
                        self.heal()
                    }
                }
            })
        }
    }

    private func viewMenu(in mainMenu: NSMenu) -> NSMenu? {
        mainMenu.items.first { $0.submenu?.title == "View" }?.submenu
    }

    /// Inserts the submenu if View doesn't hold it — after the sidebar item, where
    /// `CommandGroup(after: .sidebar)` put it, else above Enter Full Screen, else last.
    private func heal() {
        guard let mainMenu, let view = viewMenu(in: mainMenu) else { return }
        guard hostItem.menu !== view else { return }
        hostItem.menu?.removeItem(hostItem)
        let afterSidebar = view.items.firstIndex { $0.action == #selector(NSSplitViewController.toggleSidebar(_:)) }.map { $0 + 1 }
        let beforeFullScreen = view.items.firstIndex { $0.action == #selector(NSWindow.toggleFullScreen(_:)) }
        view.insertItem(hostItem, at: afterSidebar ?? beforeFullScreen ?? view.items.count)
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard let mode = mode(of: item) else { return true }
        guard let actions = registry.value(in: window()) else {
            item.state = .off
            return false
        }
        item.state = actions.mode() == mode ? .on : .off
        return actions.modes.contains(mode)
    }

    @objc private func select(_ sender: NSMenuItem) {
        guard let mode = mode(of: sender), let actions = registry.value(in: window()), actions.modes.contains(mode) else { return }
        actions.select(mode)
    }

    private func mode(of item: NSMenuItem) -> DetailLayout.InspectorMode? {
        (item.representedObject as? String).flatMap(DetailLayout.InspectorMode.init(rawValue:))
    }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }
}
