import AppKit
import XCTest
@testable import FlightDeck

/// The first ⌘N after a tab switch missed: SwiftUI rebuilt File in `menuNeedsUpdate(_:)`, which
/// AppKit calls during its key-equivalent search, and that emptied the New Session block out of
/// the menu being searched. `AppKitMenuSlot.prepareForKeyEquivalent` runs the rebuild first.
///
/// AppKit only calls `menuNeedsUpdate(_:)` mid-search for a menu in the real menu bar, which a
/// unit test has none of, so the miss itself is held by `FirstPressUITests`; these hold what
/// the fix does about it.
@MainActor
final class AppKitMenuSlotTests: XCTestCase {
    /// Stands in for SwiftUI's menu delegate: with an update pending, it empties the menu and
    /// refills it with only its own items, as SwiftUI does to File after a tab switch.
    private final class RebuildingDelegate: NSObject, NSMenuDelegate {
        var pending = false
        let own: [String]
        init(own: [String]) { self.own = own }
        func menuNeedsUpdate(_ menu: NSMenu) {
            guard pending else { return }
            pending = false
            menu.removeAllItems()
            for title in own { menu.addItem(withTitle: title, action: nil, keyEquivalent: "") }
        }
    }

    private final class Target: NSObject {
        @objc func fire(_ sender: Any?) {}
    }

    private var keep: [AnyObject] = []

    private func fileMenu() -> (main: NSMenu, file: NSMenu, delegate: RebuildingDelegate, target: Target) {
        let main = NSMenu(title: "Main")
        let file = NSMenu(title: "File")
        let delegate = RebuildingDelegate(own: ["Add Project…", "Close Session"])
        file.delegate = delegate
        for title in delegate.own { file.addItem(withTitle: title, action: nil, keyEquivalent: "") }
        main.addItem(withTitle: "File", action: nil, keyEquivalent: "").submenu = file

        let target = Target()
        let item = NSMenuItem(title: "New Claude Session", action: #selector(Target.fire(_:)), keyEquivalent: "n")
        item.keyEquivalentModifierMask = .command
        item.target = target
        let slot = AppKitMenuSlot(path: ["File"], items: [item]) { others in
            others.firstIndex { $0.title == "Add Project…" } ?? 0
        }
        slot.install(in: main)
        keep += [slot, delegate, target]
        return (main, file, delegate, target)
    }

    func testPreparingRunsAPendingRebuildThenPutsTheBlockBack() {
        let (_, file, delegate, _) = fileMenu()
        XCTAssertEqual(file.items.map(\.title), ["New Claude Session", "Add Project…", "Close Session"])
        delegate.pending = true

        AppKitMenuSlot.prepareForKeyEquivalent()
        XCTAssertFalse(delegate.pending, "the pending rebuild should run before the search, not during it")
        XCTAssertEqual(file.items.map(\.title), ["New Claude Session", "Add Project…", "Close Session"])
    }

    /// Stands in for SwiftUI rebuilding View: the Inspector item comes back with a NEW submenu,
    /// itself holding only SwiftUI's placeholder and a rebuild of its own pending.
    private final class ParentDelegate: NSObject, NSMenuDelegate {
        var pending = false
        var children: [RebuildingDelegate] = []
        func menuNeedsUpdate(_ menu: NSMenu) {
            guard pending else { return }
            pending = false
            menu.removeAllItems()
            let child = NSMenu(title: "Inspector")
            let childDelegate = RebuildingDelegate(own: ["—"])
            childDelegate.pending = true
            child.delegate = childDelegate
            children.append(childDelegate)
            menu.addItem(withTitle: "Inspector", action: nil, keyEquivalent: "").submenu = child
        }
    }

    func testPreparingFollowsThePathThroughARebuiltParent() {
        let main = NSMenu(title: "Main")
        let view = NSMenu(title: "View")
        let parent = ParentDelegate()
        view.delegate = parent
        parent.pending = true
        parent.menuNeedsUpdate(view)   // SwiftUI's first build
        main.addItem(withTitle: "View", action: nil, keyEquivalent: "").submenu = view
        let notes = NSMenuItem(title: "Notes", action: nil, keyEquivalent: "")
        let slot = AppKitMenuSlot(path: ["View", "Inspector"], hidesOthers: true, items: [notes])
        slot.install(in: main)
        keep += [slot, parent]

        parent.pending = true
        AppKitMenuSlot.prepareForKeyEquivalent()

        let inspector = view.items.first?.submenu
        XCTAssertEqual(parent.children.count, 2, "View should have rebuilt once more")
        XCTAssertFalse(parent.children.last!.pending, "the new Inspector menu's own rebuild should have run too")
        XCTAssertTrue(inspector?.items.contains(notes) ?? false, "the block should be in the rebuilt Inspector menu")
        XCTAssertEqual(inspector?.items.filter { !$0.isHidden }.map(\.title), ["Notes"])
    }
}
