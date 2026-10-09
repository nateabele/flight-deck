import AppKit

/// A block of AppKit-owned items kept inside a menu SwiftUI authored: a constant `CommandMenu`
/// shell (Tools, Run), a constant submenu shell (View ▸ Inspector), or a run of items in one of
/// SwiftUI's own menus (File's New Session items).
///
/// **Why the menu bar is built this way (the maintainer, 2026-10-09: "No menu should blink ever").**
/// Whenever SwiftUI re-evaluates a `Commands` body — any observed object publishing, any focused
/// value changing, even when the output comes out identical — it reconciles the main menu and
/// removes every top-level menu it didn't author. Tools used to be such a menu, inserted by
/// AppKit, so it blinked out and back on each tab switch, inspector mode switch and planning
/// state change. Measured in bare SwiftUI apps (`round2-inspector-mode-flicker-REPORT.md`): the
/// real `SessionCommands` removed it 11 times in 10 switches between two projects' tabs; a
/// `Commands` that observes an object whose output never changes still removed it.
///
/// Two rules follow, and `MenuBarStabilityTests` guards both:
/// - **No `Commands` reads state.** Every one in `FlightDeckCommands` is constant, so SwiftUI
///   has no reason to reconcile after launch.
/// - **Every menu that has state is AppKit items inside a menu SwiftUI authored.** Items inside
///   a SwiftUI menu survive reconciliation (0 removals in the same measurement, across output
///   changes, Settings opening and closing, and a second window coming and going), where an
///   AppKit top-level menu does not. State is answered on demand (`validateMenuItem`) or
///   written into these items in place (`setItems`), neither of which SwiftUI ever sees.
///
/// Even so, every add or remove in the bar or in the host menu is answered a turn later by
/// putting the block back where `place` says if it is not exactly there — a backstop for a
/// rebuild SwiftUI might still make on its own (a first activation, a new SwiftUI release).
@MainActor
final class AppKitMenuSlot {
    /// Titles from the main menu down to the menu that holds the block: `["File"]`,
    /// `["View", "Inspector"]`.
    private let path: [String]
    /// Where the block goes among the host's OTHER items (ours excluded).
    private let place: ([NSMenuItem]) -> Int
    /// For a shell: SwiftUI needs at least one item to build the menu at all, and that
    /// placeholder is hidden once ours are in. Hidden, not removed: SwiftUI still owns it.
    private let hidesOthers: Bool
    private(set) var items: [NSMenuItem]
    private weak var mainMenu: NSMenu?
    private var observers: [NSObjectProtocol] = []

    init(path: [String], hidesOthers: Bool = false, items: [NSMenuItem] = [],
         place: @escaping ([NSMenuItem]) -> Int = { _ in 0 }) {
        self.path = path
        self.hidesOthers = hidesOthers
        self.items = items
        self.place = place
    }

    func install(in mainMenu: NSMenu) {
        self.mainMenu = mainMenu
        heal()
        guard observers.isEmpty else { return }
        for name in [NSMenu.didRemoveItemNotification, NSMenu.didAddItemNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                // A turn later: this fires during the mutation, and changing a menu inside its
                // own change notification is not safe.
                let changed = note.object as AnyObject?
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self, let mainMenu = self.mainMenu else { return }
                        // Only the menus on our path concern us; every other menu's churn is
                        // ignored.
                        guard changed === mainMenu || self.menusOnPath(in: mainMenu).contains(where: { $0 === changed })
                        else { return }
                        self.heal()
                    }
                }
            })
        }
    }

    /// Swaps the block's items in place. Nothing SwiftUI observes changes, so this rebuilds
    /// nothing else.
    func setItems(_ new: [NSMenuItem]) {
        for item in items { item.menu?.removeItem(item) }
        items = new
        heal()
    }

    private func menusOnPath(in mainMenu: NSMenu) -> [NSMenu] {
        var menus: [NSMenu] = []
        var current = mainMenu
        for title in path {
            guard let next = current.items.first(where: { $0.submenu?.title == title })?.submenu else { break }
            menus.append(next)
            current = next
        }
        return menus
    }

    /// The menu that holds the block, once SwiftUI has built the whole path.
    var host: NSMenu? {
        guard let mainMenu else { return nil }
        let menus = menusOnPath(in: mainMenu)
        return menus.count == path.count ? menus.last : nil
    }

    /// Puts the block where `place` says unless it is already exactly there.
    func heal() {
        guard let menu = host else { return }
        let ours = Set(items.map(ObjectIdentifier.init))
        let others = menu.items.filter { !ours.contains(ObjectIdentifier($0)) }
        if hidesOthers { for item in others where !item.isHidden { item.isHidden = true } }
        let index = min(max(place(others), 0), others.count)
        let wanted = Array(others[..<index]) + items + Array(others[index...])
        guard menu.items.map(ObjectIdentifier.init) != wanted.map(ObjectIdentifier.init) else { return }
        for item in items { item.menu?.removeItem(item) }
        for (offset, item) in items.enumerated() { menu.insertItem(item, at: index + offset) }
    }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }
}
