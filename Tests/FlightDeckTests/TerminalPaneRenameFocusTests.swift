import XCTest
@testable import FlightDeck

/// Whether a re-parented terminal takes keyboard focus. It must not while the newly selected
/// session's own rename field is open: the row menu's Rename on a row that was NOT selected
/// selects it and opens the field in one step, the re-parent then handed focus to the terminal,
/// the field's focus loss committed it, and the field closed within one frame (a UI-test Mac
/// recording, 2026-10-09: one frame of field at 30 fps, then the plain title).
@MainActor
final class TerminalPaneRenameFocusTests: XCTestCase {
    private let a = UUID()
    private let b = UUID()

    func testAPlainSessionSwitchFocusesTheTerminal() {
        XCTAssertTrue(TerminalPane.claimsFocusOnReparent(selected: a, renaming: nil))
    }

    func testARenameOfTheSessionBeingShownKeepsTheField() {
        XCTAssertFalse(TerminalPane.claimsFocusOnReparent(selected: a, renaming: a))
    }

    func testAStaleRenameOfAnotherRowDoesNotBlockFocus() {
        // Clicking row B while row A's field is open: A's commit may not have cleared the flag
        // by the time B's surface is attached, and B's terminal must still get the keyboard.
        XCTAssertTrue(TerminalPane.claimsFocusOnReparent(selected: b, renaming: a))
    }
}
