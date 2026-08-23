import XCTest
@testable import FleetKit

/// The validator that stands between a paired phone and a pty.
///
/// Every test here is written against a specific way of getting it wrong, and the fixtures
/// are built to distinguish: the control-character case carries a real bracketed-paste
/// terminator rather than a bare `\u{1b}`, and the tab/newline case carries both characters
/// rather than one, so a rule that handled only half of either would fail rather than pass.
final class PromptTextTests: XCTestCase {
    /// The load-bearing one. `sendText` is a paste, and ghostty wraps a paste in
    /// `ESC [ 200~ … ESC [ 201~`. Text carrying the closing marker ends the paste early and
    /// everything after it is read as raw terminal input.
    func testAnEscapeSequenceIsRefusedBecauseItCanCloseABracketedPaste() {
        XCTAssertEqual(
            PromptText.rejection(for: "please continue\u{1b}[201~\u{1b}[Bmalicious"),
            .controlCharacters
        )
        XCTAssertNil(PromptText("please continue\u{1b}[201~\u{1b}[Bmalicious"))
    }

    func testACarriageReturnIsRefusedRatherThanNormalised() {
        XCTAssertEqual(PromptText.rejection(for: "one\r\ntwo"), .controlCharacters)
    }

    /// The negative control, and it needs both characters: a rule that allowed newline and
    /// rejected tab would pass a fixture holding only a newline.
    func testTabAndNewlineSurviveBecauseTheyArePastedContent() {
        XCTAssertEqual(PromptText("run this:\n\tswift build")?.value, "run this:\n\tswift build")
    }

    /// `inject` sends the text and then Return as a separate key event, so a trailing
    /// newline inserts a blank line into the input box instead of submitting anything.
    func testTrailingNewlinesAreStrippedSoReturnSubmitsRatherThanInserts() {
        XCTAssertEqual(PromptText("ship it\n\n")?.value, "ship it")
    }

    func testWhitespaceOnlyIsEmptyRatherThanSendable() {
        XCTAssertEqual(PromptText.rejection(for: "   \n  \t "), .empty)
        XCTAssertNil(PromptText("   \n  \t "))
    }

    /// Both sides of the boundary, so an off-by-one in either direction fails.
    func testTheCapIsInclusive() {
        XCTAssertNil(PromptText.rejection(for: String(repeating: "a", count: PromptText.maxCharacters)))
        XCTAssertEqual(
            PromptText.rejection(for: String(repeating: "a", count: PromptText.maxCharacters + 1)),
            .tooLong
        )
    }

    /// The cap is not arbitrary: the phone confirms a send by finding its own text verbatim
    /// in a transcript page, and a body at or over `maxItemBytes` comes back truncated. A
    /// prompt that could be truncated is a prompt whose confirmation could never arrive.
    func testTheCapSitsBelowTheItemBodyCapSoAConfirmationCanAlwaysArrive() {
        XCTAssertLessThan(PromptText.maxCharacters, TimelineLimits.maxItemBytes)
    }

    /// These strings are `err`'s `code` on the wire, so a case rename must not silently
    /// become a protocol break — the same rule `TimelineAnchor.name` states.
    func testRejectionCodesAreTheWireSpelling() {
        XCTAssertEqual(PromptText.Rejection.empty.rawValue, "prompt_empty")
        XCTAssertEqual(PromptText.Rejection.tooLong.rawValue, "prompt_too_long")
        XCTAssertEqual(PromptText.Rejection.controlCharacters.rawValue, "prompt_control_characters")
    }
}
