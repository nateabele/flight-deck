import AppKit
import XCTest
@testable import FlightDeck

final class ShortcutCatalogTests: XCTestCase {
    private typealias Node = ShortcutCatalog.MenuNode

    private func item(_ title: String, _ key: String, _ mods: NSEvent.ModifierFlags = .command,
                      hidden: Bool = false) -> Node {
        Node(title: title, keyEquivalent: key, modifiers: mods, isHidden: hidden, children: [])
    }
    private func menu(_ title: String, _ children: [Node]) -> Node {
        Node(title: title, keyEquivalent: "", modifiers: [], isHidden: false, children: children)
    }

    func testChordOrdersModifiersLikeTheMenuBar() {
        XCTAssertEqual(ShortcutCatalog.chord(key: "v", modifiers: [.command, .shift, .option]), "⌥⇧⌘V")
        XCTAssertEqual(ShortcutCatalog.chord(key: "t", modifiers: [.command, .shift]), "⇧⌘T")
    }

    func testUppercaseKeyImpliesShift() {
        XCTAssertEqual(ShortcutCatalog.chord(key: "T", modifiers: .command), "⇧⌘T")
    }

    func testArrowsAndPunctuation() {
        let left = String(Character(UnicodeScalar(NSLeftArrowFunctionKey)!))
        XCTAssertEqual(ShortcutCatalog.chord(key: left, modifiers: [.command, .control]), "⌃⌘←")
        XCTAssertEqual(ShortcutCatalog.chord(key: "[", modifiers: [.command, .shift]), "⇧⌘[")
        XCTAssertEqual(ShortcutCatalog.chord(key: "?", modifiers: .command), "⌘?")
    }

    func testReturnAndEscape() {
        XCTAssertEqual(ShortcutCatalog.chord(key: "\r", modifiers: .command), "⌘↩")
        XCTAssertEqual(ShortcutCatalog.chord(key: "\u{1B}", modifiers: .command), "⌘⎋")
    }

    func testForwardDelete() {
        let delete = String(Character(UnicodeScalar(NSDeleteFunctionKey)!))
        XCTAssertEqual(ShortcutCatalog.chord(key: delete, modifiers: .command), "⌘⌦")
    }

    func testFunctionKeys() {
        let f1 = String(Character(UnicodeScalar(NSF1FunctionKey)!))
        let f12 = String(Character(UnicodeScalar(NSF12FunctionKey)!))
        XCTAssertEqual(ShortcutCatalog.chord(key: f1, modifiers: .command), "⌘F1")
        XCTAssertEqual(ShortcutCatalog.chord(key: f12, modifiers: .command), "⌘F12")
    }

    func testGroupsFollowTopLevelMenusAndFlattenSubmenus() {
        let groups = ShortcutCatalog.groups(from: [
            menu("File", [item("New Session", "n"), menu("Open Recent", [item("Clear", "k")])]),
            menu("Edit", [item("Find…", "f")]),
        ])
        XCTAssertEqual(groups.map(\.title), ["File", "Edit"])
        XCTAssertEqual(groups[0].items.map(\.title), ["New Session", "Clear"])
    }

    func testItemsWithoutAChordHiddenItemsAndEmptyMenusAreDropped() {
        let groups = ShortcutCatalog.groups(from: [
            menu("File", [item("About", ""), item("Secret", "s", hidden: true), item("Close", "w")]),
            menu("Window", [item("Zoom", "")]),
        ])
        XCTAssertEqual(groups.map(\.title), ["File"])
        XCTAssertEqual(groups[0].items.map(\.title), ["Close"])
    }

    func testFilterMatchesTitleCaseInsensitively() {
        let groups = ShortcutCatalog.groups(from: [menu("File", [item("New Session", "n"), item("Close", "w")])])
        XCTAssertEqual(ShortcutCatalog.filter(groups, query: "sess").first?.items.map(\.title), ["New Session"])
    }

    func testFilterMatchesChordText() {
        let groups = ShortcutCatalog.groups(from: [menu("File", [item("New Session", "n"), item("Close", "w")])])
        XCTAssertEqual(ShortcutCatalog.filter(groups, query: "⌘N").first?.items.map(\.title), ["New Session"])
    }

    func testFilterDropsGroupsLeftEmptyAndBlankQueryKeepsAll() {
        let groups = ShortcutCatalog.groups(from: [
            menu("File", [item("Close", "w")]), menu("Edit", [item("Find…", "f")]),
        ])
        XCTAssertEqual(ShortcutCatalog.filter(groups, query: "find").map(\.title), ["Edit"])
        XCTAssertEqual(ShortcutCatalog.filter(groups, query: "  "), groups)
    }
}
