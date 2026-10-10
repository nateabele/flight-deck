import AppKit
import SwiftUI
import XCTest
@testable import FlightDeck

/// The Run menu as AppKit items in the `RunMenuShell` SwiftUI authors, acting on the shaping run
/// in the window through `PaneMenus.planning`. A plan coming on or off screen, or the lit
/// buttons changing mid-run, changes only what validation answers — never the menu.
@MainActor
final class RunMenuControllerTests: XCTestCase {
    private var mainMenu: NSMenu!
    private var registry: PaneMenuRegistry<PlanningActions>!
    private var controller: RunMenuController!
    private var window: NSWindow!
    private var pressed: [TransportButton] = []
    private var heatmapOpen = false

    override func setUp() {
        super.setUp()
        mainMenu = NSMenu(title: "Main")
        let shell = NSMenu(title: RunMenuShell.title)
        shell.addItem(NSMenuItem(title: "—", action: nil, keyEquivalent: ""))
        let host = NSMenuItem(title: RunMenuShell.title, action: nil, keyEquivalent: "")
        host.submenu = shell
        mainMenu.addItem(host)
        registry = PaneMenuRegistry()
        controller = RunMenuController(registry: registry)
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

    private var shell: NSMenu { mainMenu.items[0].submenu! }
    private func item(_ title: String) -> NSMenuItem { controller.items.first { $0.title == title }! }

    private func actions(_ enabled: Set<TransportButton>, heatmap: Bool = true) -> PlanningActions {
        var actions = PlanningActions(enabled: enabled, intakeID: UUID()) { [unowned self] in pressed.append($0) }
        if heatmap {
            actions.heatmap = .init(open: heatmapOpen) { [unowned self] in heatmapOpen.toggle() }
        }
        return actions
    }

    private func show(_ actions: PlanningActions?) {
        let host = NSHostingView(rootView: PaneMenuAnchor(registry: registry, value: actions).frame(width: 10, height: 10))
        window.contentView = host
        host.layoutSubtreeIfNeeded()
    }

    private func fire(_ item: NSMenuItem) { _ = controller.perform(item.action!, with: item) }

    func testTheItemsAndChordsFillTheShell() {
        XCTAssertEqual(shell.items.filter { !$0.isHidden && !$0.isSeparatorItem }.map(\.title),
                       ["Step", "Next Major", "To Review", "Pause", "Stop", "Extend", "Remove a Round", "Annotate",
                        "Show Section Heatmap"])
        XCTAssertEqual(item("Stop").keyEquivalent, ".")
        XCTAssertEqual(item("Stop").keyEquivalentModifierMask, [.command])
        XCTAssertEqual(item("Next Major").keyEquivalentModifierMask, [.command, .shift])
        XCTAssertEqual(item("Annotate").keyEquivalentModifierMask, [.command, .option])
    }

    func testNoRunOnScreenDisablesEverything() {
        for item in controller.items where !item.isSeparatorItem {
            XCTAssertFalse(controller.validateMenuItem(item), item.title)
        }
        show(nil)
        XCTAssertFalse(controller.validateMenuItem(item("Stop")), "a plan that isn't shaping registers nothing")
    }

    /// The lit buttons change mid-run: validation follows, the menu is the same objects.
    func testEnablementFollowsTheRunWithoutRebuildingTheMenu() {
        let before = shell.items.map(ObjectIdentifier.init)
        show(actions([.step, .stop]))
        XCTAssertTrue(controller.validateMenuItem(item("Step")))
        XCTAssertFalse(controller.validateMenuItem(item("Pause")))
        fire(item("Step"))
        fire(item("Pause"))
        XCTAssertEqual(pressed, [.step], "a dark button's item does nothing even if it fires")

        show(actions([.pause]))
        XCTAssertFalse(controller.validateMenuItem(item("Step")))
        XCTAssertTrue(controller.validateMenuItem(item("Pause")))
        XCTAssertEqual(shell.items.map(ObjectIdentifier.init), before, "no item was added, removed or replaced")
    }

    func testTheHeatmapItemNamesItsStateAndToggles() {
        show(actions([], heatmap: true))
        XCTAssertTrue(controller.validateMenuItem(item("Show Section Heatmap")))
        fire(item("Show Section Heatmap"))
        XCTAssertTrue(heatmapOpen)
        show(actions([], heatmap: true))
        let heatmap = controller.items.last!
        _ = controller.validateMenuItem(heatmap)
        XCTAssertEqual(heatmap.title, "Hide Section Heatmap")

        show(actions([], heatmap: false))
        XCTAssertFalse(controller.validateMenuItem(heatmap), "no per-section numbers yet")
    }

    /// A tab switch takes the pane out of the window: everything disables, nothing is rebuilt.
    func testLeavingThePlanDisablesTheItems() {
        show(actions([.step]))
        XCTAssertTrue(controller.validateMenuItem(item("Step")))
        window.contentView = NSView()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        XCTAssertFalse(controller.validateMenuItem(item("Step")))
    }
}
