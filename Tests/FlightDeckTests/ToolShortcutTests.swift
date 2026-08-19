import AppKit
import XCTest
@testable import FlightDeck

@MainActor
final class ToolShortcutTests: XCTestCase {
    func testKeyIsLowercasedSoItMatchesAMenuKeyEquivalent() {
        // `NSMenuItem.keyEquivalent` is case-sensitive, and an uppercase letter there means
        // "shift is part of the equivalent" — recording "O" would produce a chord that needs
        // shift held on top of whatever modifiers were captured.
        XCTAssertEqual(ToolShortcut(key: "O", modifiers: [.command]).key, "o")
    }

    func testOnlyDeviceIndependentModifiersAreStored() {
        // A raw `NSEvent.modifierFlags` carries device-dependent bits and caps lock; storing
        // them would make an otherwise-identical chord fail to compare equal across launches.
        let recorded = ToolShortcut(key: "o", modifiers: [.command, .capsLock])
        XCTAssertFalse(recorded.modifierFlags.contains(.capsLock))
        XCTAssertTrue(recorded.modifierFlags.contains(.command))
    }

    func testRoundTripsThroughAMenuItem() {
        let shortcut = ToolShortcut(key: "o", modifiers: [.command, .shift])
        let item = NSMenuItem(title: "Editor", action: nil, keyEquivalent: shortcut.key)
        item.keyEquivalentModifierMask = shortcut.modifierFlags
        XCTAssertEqual(item.keyEquivalent, "o")
        XCTAssertEqual(item.keyEquivalentModifierMask, [.command, .shift])
    }

    func testDisplayStringUsesTheConventionalModifierOrder() {
        // Same order `NewSessionAffordance.display` uses, which is the order macOS renders.
        XCTAssertEqual(ToolShortcut(key: "o", modifiers: [.command]).displayString, "⌘O")
        XCTAssertEqual(ToolShortcut(key: "g", modifiers: [.command, .shift]).displayString, "⇧⌘G")
        XCTAssertEqual(
            ToolShortcut(key: "t", modifiers: [.command, .shift, .option, .control]).displayString,
            "⌃⌥⇧⌘T"
        )
    }

    func testCodableRoundTrip() throws {
        let tool = ToolDefinition(
            name: "Editor",
            symbol: "chevron.left.forwardslash.chevron.right",
            command: "$EDITOR ${cwd}",
            shortcut: ToolShortcut(key: "o", modifiers: [.command])
        )
        let data = try JSONEncoder().encode(tool)
        XCTAssertEqual(try JSONDecoder().decode(ToolDefinition.self, from: data), tool)
    }

    func testAToolDefaultsToShowingInTheOverlay() {
        XCTAssertTrue(ToolDefinition(name: "x", symbol: "gear", command: "true").showsInOverlay)
    }
}
