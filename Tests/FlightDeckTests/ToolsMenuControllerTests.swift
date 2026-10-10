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

    /// The bar as SwiftUI builds it with `ToolsMenuShell`: a Tools menu SwiftUI authored, holding
    /// its one placeholder.
    private func barWithShell() -> NSMenu {
        let main = NSMenu()
        main.addItem(withTitle: "View", action: nil, keyEquivalent: "").submenu = NSMenu(title: "View")
        let shell = NSMenu(title: ToolsMenuShell.title)
        shell.addItem(withTitle: "—", action: nil, keyEquivalent: "")
        main.addItem(withTitle: "Tools", action: nil, keyEquivalent: "").submenu = shell
        main.addItem(withTitle: "Window", action: nil, keyEquivalent: "").submenu = NSMenu(title: "Window")
        return main
    }

    private func turn() { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }

    private func shell(_ main: NSMenu) -> NSMenu { main.items.first { $0.submenu?.title == "Tools" }!.submenu! }

    /// The items go INTO the SwiftUI-authored menu, so SwiftUI's reconciliation, which removes
    /// only top-level menus it didn't author, never removes Tools. It used to be an AppKit
    /// top-level menu, removed and put back on every reconciliation: the blink.
    func testTheItemsFillTheSwiftUIShellAndAddNoMenuOfTheirOwn() {
        let main = barWithShell()
        let controller = ToolsMenuController()
        controller.tools = [tool("Editor", "o")]
        controller.install(in: main)
        controller.install(in: main)
        XCTAssertEqual(main.items.map { $0.submenu?.title }, ["View", "Tools", "Window"], "no menu added or moved")
        XCTAssertEqual(shell(main).items.filter { !$0.isHidden }.map(\.title), ["Editor", "", "Configure Tools…"])
        XCTAssertEqual(shell(main).items.filter(\.isHidden).map(\.title), ["—"], "SwiftUI's placeholder, hidden")
        XCTAssertEqual(shell(main).items.first?.keyEquivalent, "o", "the chord is live in the bar")
    }

    func testEditingTheToolsRewritesTheShellInPlace() {
        let main = barWithShell()
        let controller = ToolsMenuController()
        controller.install(in: main)
        let shellBefore = shell(main)
        controller.tools = [tool("Tower", "g"), tool("Editor", "o")]
        XCTAssertTrue(shell(main) === shellBefore)
        XCTAssertEqual(shell(main).items.filter { !$0.isHidden }.prefix(2).map(\.title), ["Tower", "Editor"])
        XCTAssertEqual(main.items.count, 3)
    }

    /// Before SwiftUI has built the shell, installing waits for it; the items follow it in.
    func testTheItemsFollowAShellBuiltLater() {
        let main = NSMenu()
        main.addItem(withTitle: "View", action: nil, keyEquivalent: "").submenu = NSMenu(title: "View")
        let controller = ToolsMenuController()
        controller.tools = [tool("Editor", "o")]
        controller.install(in: main)
        let shell = NSMenu(title: ToolsMenuShell.title)
        shell.addItem(withTitle: "—", action: nil, keyEquivalent: "")
        main.addItem(withTitle: "Tools", action: nil, keyEquivalent: "").submenu = shell
        turn()
        XCTAssertEqual(shell.items.filter { !$0.isHidden }.first?.title, "Editor")
    }
}
