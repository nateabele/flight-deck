// Tests/FlightDeckTests/MenuKeyEquivalentsTests.swift
import XCTest
@testable import FlightDeck

/// Pins which Ghostty bindings get handed to the menu. Getting this wrong is silent in both
/// directions: too permissive and the terminal stops receiving keys it should handle; too
/// strict and menu shortcuts are swallowed, which is the bug this logic exists to fix.
final class MenuKeyEquivalentsTests: XCTestCase {
    private func offer(
        _ flags: Ghostty.Input.BindingFlags,
        inKeySequence: Bool = false,
        inKeyTable: Bool = false
    ) -> Bool {
        MenuKeyEquivalents.shouldOfferToMenu(
            bindingFlags: flags, inKeySequence: inKeySequence, inKeyTable: inKeyTable
        )
    }

    /// The ⌘Q case: an ordinary consumed binding must reach the menu.
    func testConsumedBindingIsOfferedToTheMenu() {
        XCTAssertTrue(offer([.consumed]))
    }

    /// `all` bindings dispatch through the responder chain the menu itself uses.
    func testAllBindingIsWithheld() {
        XCTAssertFalse(offer([.consumed, .all]))
    }

    /// `performable` bindings must reach the terminal even when a menu item shares the key.
    func testPerformableBindingIsWithheld() {
        XCTAssertFalse(offer([.consumed, .performable]))
    }

    /// Unconsumed bindings are meant to pass through to the terminal.
    func testUnconsumedBindingIsWithheld() {
        XCTAssertFalse(offer([]))
        XCTAssertFalse(offer([.global]))
    }

    /// `global` is orthogonal — it must not by itself block the menu hand-off.
    func testGlobalFlagDoesNotBlockAConsumedBinding() {
        XCTAssertTrue(offer([.consumed, .global]))
    }

    /// A multi-stroke binding in flight: handing an intermediate stroke to the menu
    /// would break the sequence.
    func testMidKeySequenceIsWithheld() {
        XCTAssertFalse(offer([.consumed], inKeySequence: true))
    }

    func testMidKeyTableIsWithheld() {
        XCTAssertFalse(offer([.consumed], inKeyTable: true))
    }
}
