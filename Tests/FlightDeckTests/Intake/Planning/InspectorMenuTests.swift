import AppKit
import SwiftUI
import XCTest
@testable import FlightDeck

/// View ▸ Inspector as AppKit items over `PaneMenuRegistry`, inside the submenu SwiftUI authors
/// (`InspectorMenuShell`). What these pin is the shape that keeps the menu bar still: a mode or
/// tab switch changes what validation answers, never the menu itself, and the items survive
/// SwiftUI replacing the shell.
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

    /// View as SwiftUI builds it: the sidebar item, then the shell with its one placeholder.
    private static func viewMenu() -> NSMenu {
        let view = NSMenu(title: "View")
        view.addItem(NSMenuItem(title: "Show Sidebar", action: #selector(NSSplitViewController.toggleSidebar(_:)), keyEquivalent: "s"))
        let shell = NSMenu(title: InspectorMenuShell.title)
        shell.addItem(NSMenuItem(title: "—", action: nil, keyEquivalent: ""))
        view.addItem(host(shell))
        view.addItem(.separator())
        view.addItem(NSMenuItem(title: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f"))
        return view
    }

    private var view: NSMenu { mainMenu.items.first { $0.submenu?.title == "View" }!.submenu! }
    private var shell: NSMenu { view.items.first { $0.submenu?.title == InspectorMenuShell.title }!.submenu! }

    private func item(_ mode: Mode) -> NSMenuItem { controller.items.first { $0.title == mode.title }! }

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

    func testTheItemsFillTheShellWithTheirChords() {
        XCTAssertEqual(shell.items.filter { !$0.isHidden }.map(\.title), ["Notes", "Rounds"])
        XCTAssertEqual(shell.items.filter(\.isHidden).map(\.title), ["—"], "SwiftUI's placeholder, hidden, not removed")
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
        let items = shell.items.map(ObjectIdentifier.init)
        XCTAssertTrue(controller.validateMenuItem(item(.rounds)))
        XCTAssertEqual(item(.rounds).state, .on)
        XCTAssertEqual(item(.notes).state, .off)

        _ = controller.perform(item(.notes).action!, with: item(.notes))
        XCTAssertEqual(selected, [.notes])
        _ = controller.validateMenuItem(item(.notes)); _ = controller.validateMenuItem(item(.rounds))
        XCTAssertEqual(item(.notes).state, .on)
        XCTAssertEqual(item(.rounds).state, .off)
        XCTAssertEqual(shell.items.map(ObjectIdentifier.init), items, "the menu was not rebuilt")
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

    /// If SwiftUI ever rebuilds the shell or View (a fresh `NSMenu`), the items follow a turn later.
    func testTheItemsFollowARebuiltShell() {
        let viewIndex = mainMenu.items.firstIndex { $0.submenu?.title == "View" }!
        mainMenu.removeItem(at: viewIndex)
        mainMenu.insertItem(Self.host(Self.viewMenu()), at: viewIndex)
        turn()
        XCTAssertEqual(shell.items.filter { !$0.isHidden }.map(\.title), ["Notes", "Rounds"], "moved into the new shell")
        XCTAssertTrue(controller.menu === shell)
    }
}
