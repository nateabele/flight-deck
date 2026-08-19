import AppKit
import XCTest
@testable import FlightDeck

@MainActor
final class ToolsMenuControllerTests: XCTestCase {
    private func tool(_ name: String, _ key: String?) -> ToolDefinition {
        ToolDefinition(
            name: name, symbol: "gear", command: "true",
            shortcut: key.map { ToolShortcut(key: $0, modifiers: [.command]) }
        )
    }

    func testItemsCarryTheirNamesAndKeyEquivalents() {
        let controller = ToolsMenuController()
        controller.tools = [tool("Editor", "o"), tool("Terminal", "t")]
        let items = controller.menu.items
        XCTAssertEqual(items[0].title, "Editor")
        XCTAssertEqual(items[0].keyEquivalent, "o")
        XCTAssertEqual(items[0].keyEquivalentModifierMask, [.command])
        XCTAssertEqual(items[1].title, "Terminal")
        XCTAssertEqual(items[1].keyEquivalent, "t")
    }

    func testAToolWithNoShortcutStillGetsAnItem() {
        let controller = ToolsMenuController()
        controller.tools = [tool("Tower", nil)]
        XCTAssertEqual(controller.menu.items.first?.title, "Tower")
        XCTAssertEqual(controller.menu.items.first?.keyEquivalent, "")
    }

    func testTheMenuAlwaysEndsWithASeparatorAndConfigure() {
        let controller = ToolsMenuController()
        controller.tools = [tool("Editor", "o")]
        let items = controller.menu.items
        XCTAssertTrue(items[items.count - 2].isSeparatorItem)
        XCTAssertEqual(items.last?.title, "Configure Tools…")
    }

    func testAnEmptyToolListStillOffersConfigure() {
        // Deleting every tool must not leave a dead menu with no way back to the pane.
        let controller = ToolsMenuController()
        controller.tools = []
        XCTAssertEqual(controller.menu.items.last?.title, "Configure Tools…")
    }

    func testChangingTheToolsRebuildsTheMenu() {
        let controller = ToolsMenuController()
        controller.tools = [tool("Editor", "o")]
        controller.tools = [tool("Tower", "g"), tool("Editor", "o")]
        XCTAssertEqual(controller.menu.items.prefix(2).map(\.title), ["Tower", "Editor"])
    }

    func testItemsAreDisabledWithoutASelectedSession() {
        // No selection means no working directory, so the chord must be inert rather than
        // launching a tool somewhere arbitrary. A disabled NSMenuItem does not fire its key
        // equivalent, which is exactly what is wanted here.
        let controller = ToolsMenuController()
        controller.isEnabled = { false }
        controller.tools = [tool("Editor", "o")]
        XCTAssertFalse(controller.validateMenuItem(controller.menu.items[0]))
    }

    func testConfigureStaysEnabledWithoutASelectedSession() {
        let controller = ToolsMenuController()
        controller.isEnabled = { false }
        controller.tools = [tool("Editor", "o")]
        XCTAssertTrue(controller.validateMenuItem(controller.menu.items.last!))
    }

    func testActivatingAnItemRunsThatTool() {
        let controller = ToolsMenuController()
        var ran: [String] = []
        controller.run = { ran.append($0.name) }
        controller.tools = [tool("Editor", "o"), tool("Terminal", "t")]
        let item = controller.menu.items[1]
        _ = item.target?.perform(item.action!, with: item)
        XCTAssertEqual(ran, ["Terminal"])
    }

    func testInstallingTwiceLeavesOneToolsMenu() {
        // `install` runs whenever the main menu is rebuilt, so it has to be idempotent.
        let main = NSMenu()
        main.addItem(withTitle: "View", action: nil, keyEquivalent: "").submenu = NSMenu(title: "View")
        main.addItem(withTitle: "Window", action: nil, keyEquivalent: "").submenu = NSMenu(title: "Window")
        let controller = ToolsMenuController()
        controller.install(in: main)
        controller.install(in: main)
        XCTAssertEqual(main.items.filter { $0.submenu?.title == "Tools" }.count, 1)
    }

    func testTheMenuLandsAfterViewWhenViewExists() {
        let main = NSMenu()
        main.addItem(withTitle: "View", action: nil, keyEquivalent: "").submenu = NSMenu(title: "View")
        main.addItem(withTitle: "Window", action: nil, keyEquivalent: "").submenu = NSMenu(title: "Window")
        ToolsMenuController().install(in: main)
        XCTAssertEqual(main.items.map { $0.submenu?.title }, ["View", "Tools", "Window"])
    }

    func testTheMenuLandsBeforeWindowWhenViewIsAbsent() {
        // SwiftUI builds the main menu asynchronously, so installing before View exists is a
        // real ordering, not a hypothetical one.
        let main = NSMenu()
        main.addItem(withTitle: "Window", action: nil, keyEquivalent: "").submenu = NSMenu(title: "Window")
        ToolsMenuController().install(in: main)
        XCTAssertEqual(main.items.map { $0.submenu?.title }, ["Tools", "Window"])
    }
}
