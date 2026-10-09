import AppKit
import SwiftUI
import XCTest
@testable import FlightDeck

/// View ▸ Inspector as AppKit items over `PaneMenuRegistry`. What these pin is the shape that
/// keeps the menu bar still: a mode or tab switch changes what validation answers, never the
/// menu itself, and the submenu survives SwiftUI pruning or replacing View.
@MainActor
final class InspectorMenuTests: XCTestCase {
    private typealias Mode = DetailLayout.InspectorMode

    private var mainMenu: NSMenu!
    private var registry: PaneMenuRegistry<InspectorModeActions>!
    private var controller: InspectorMenuController!
    private var window: NSWindow!
    private var mode: Mode = .rounds
    private var selected: [Mode] = []

    override func setUp() {
        super.setUp()
        mainMenu = NSMenu(title: "Main")
        mainMenu.addItem(Self.host(NSMenu(title: "File")))
        mainMenu.addItem(Self.host(Self.viewMenu()))
        mainMenu.addItem(Self.host(NSMenu(title: "Window")))
        registry = PaneMenuRegistry()
        controller = InspectorMenuController(registry: registry)
        window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 200, height: 100),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        controller.window = { [unowned self] in window }
        controller.install(in: mainMenu)
    }

    override func tearDown() {
        window.orderOut(nil)
        controller = nil
        super.tearDown()
    }

    private static func host(_ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    private static func viewMenu() -> NSMenu {
        let view = NSMenu(title: "View")
        view.addItem(NSMenuItem(title: "Show Sidebar", action: #selector(NSSplitViewController.toggleSidebar(_:)), keyEquivalent: "s"))
        view.addItem(.separator())
        view.addItem(NSMenuItem(title: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f"))
        return view
    }

    private var view: NSMenu { mainMenu.items.first { $0.submenu?.title == "View" }!.submenu! }

    private func item(_ mode: Mode) -> NSMenuItem { controller.menu.items.first { $0.title == mode.title }! }

    private func actions(modes: [Mode] = [.notes, .rounds]) -> InspectorModeActions {
        InspectorModeActions(intakeID: UUID(), modes: modes, mode: { [unowned self] in mode },
                             select: { [unowned self] in selected.append($0); mode = $0 })
    }

    /// An anchor view in `window`, as the pane's `PaneMenuAnchor` puts one.
    private func showPane(_ actions: InspectorModeActions) -> NSView {
        let anchor = PaneMenuAnchor(registry: registry, value: actions)
        let host = NSHostingView(rootView: anchor.frame(width: 10, height: 10))
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        return host
    }

    private func turn() { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }

    func testTheSubmenuSitsAfterTheSidebarItemWithItsChords() {
        let index = view.items.firstIndex { $0.submenu === controller.menu }
        XCTAssertEqual(index, 1, "right after Show Sidebar, where CommandGroup(after: .sidebar) put it")
        XCTAssertEqual(item(.notes).keyEquivalent, "1")
        XCTAssertEqual(item(.rounds).keyEquivalent, "2")
        XCTAssertEqual(item(.rounds).keyEquivalentModifierMask, [.command, .option])
    }

    func testNoPaneDisablesBothItems() {
        XCTAssertFalse(controller.validateMenuItem(item(.notes)))
        XCTAssertFalse(controller.validateMenuItem(item(.rounds)))
        XCTAssertEqual(item(.rounds).state, .off)
    }

    /// A mode switch changes what validation answers and nothing else: the same `NSMenu`, the
    /// same items. That is the whole fix — nothing for SwiftUI to reconcile.
    func testAModeSwitchMovesTheCheckmarkWithoutTouchingTheMenu() {
        _ = showPane(actions())
        let items = controller.menu.items.map(ObjectIdentifier.init)
        XCTAssertTrue(controller.validateMenuItem(item(.rounds)))
        XCTAssertEqual(item(.rounds).state, .on)
        XCTAssertEqual(item(.notes).state, .off)

        _ = controller.perform(item(.notes).action!, with: item(.notes))
        XCTAssertEqual(selected, [.notes])
        _ = controller.validateMenuItem(item(.notes)); _ = controller.validateMenuItem(item(.rounds))
        XCTAssertEqual(item(.notes).state, .on)
        XCTAssertEqual(item(.rounds).state, .off)
        XCTAssertEqual(controller.menu.items.map(ObjectIdentifier.init), items, "the menu was not rebuilt")
        XCTAssertTrue(view.items.contains { $0.submenu === controller.menu })
    }

    func testASingleTaskOffersNotesOnly() {
        mode = .notes
        _ = showPane(actions(modes: [.notes]))
        XCTAssertTrue(controller.validateMenuItem(item(.notes)))
        XCTAssertFalse(controller.validateMenuItem(item(.rounds)))
        _ = controller.perform(item(.rounds).action!, with: item(.rounds))
        XCTAssertEqual(selected, [], "a disabled mode's item does nothing even if it fires")
    }

    /// A tab switch takes the pane out of the window: the items disable, with no menu change.
    func testLeavingThePlanDisablesTheItems() {
        _ = showPane(actions())
        XCTAssertTrue(controller.validateMenuItem(item(.notes)))
        window.contentView = NSView()
        turn()
        XCTAssertFalse(controller.validateMenuItem(item(.notes)), "the window shows no plan any more")
    }

    /// SwiftUI prunes items it didn't author from View, or hands the bar a fresh View menu; the
    /// submenu comes back a turn later either way.
    func testTheSubmenuHealsAfterAPruneOrAReplacedViewMenu() {
        view.removeItem(at: view.items.firstIndex { $0.submenu === controller.menu }!)
        turn()
        XCTAssertTrue(view.items.contains { $0.submenu === controller.menu }, "healed after a prune")

        let viewIndex = mainMenu.items.firstIndex { $0.submenu?.title == "View" }!
        mainMenu.removeItem(at: viewIndex)
        mainMenu.insertItem(Self.host(Self.viewMenu()), at: viewIndex)
        turn()
        XCTAssertTrue(view.items.contains { $0.submenu === controller.menu }, "healed into the new View menu")
        XCTAssertEqual(view.items.filter { $0.submenu === controller.menu }.count, 1)
    }
}
