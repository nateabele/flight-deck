import XCTest
@testable import FlightDeck

/// The fake **models** the option list rather than merely recording against it — the same
/// decision `SpyInjector`'s input-bar modelling documents, and for the same reason: a fake that
/// ignored what a keystroke DOES would let the dangerous case pass. `SessionStore.choose`
/// re-reads the screen after moving and refuses Return unless the marker landed, so a fake
/// whose screen never changed would make that check untestable.
///
/// The split between the first test and the rest is deliberate, and it is what keeps each one
/// falsifiable on its own. `testAnArrowMovesTheMarkerOnTheModelledScreen` is the only test that
/// reads the *screen*; it is what ties the modelled selection to what a parser would see. The
/// others assert the model directly, so a mutation to the rendering kills exactly one test and
/// a mutation to the movement kills exactly the tests about movement — rather than every test
/// in the file failing together and proving only that something, somewhere, broke.
@MainActor
final class SpyInjectorOptionsTests: XCTestCase {
    func testAnArrowMovesTheMarkerOnTheModelledScreen() throws {
        let spy = SpyInjector()
        spy.showOptions(["Yes", "No", "Maybe"], selected: 0)
        XCTAssertEqual(
            markedOption(in: try XCTUnwrap(spy.readViewport()))?.index, 0,
            "the screen must show the marker before the arrow, or the move proves nothing"
        )
        spy.sendArrowDown()
        let marked = try XCTUnwrap(markedOption(in: try XCTUnwrap(spy.readViewport())))
        XCTAssertEqual(marked.index, 1)
        XCTAssertEqual(marked.label, "No")
    }

    func testTheMarkerDoesNotRunOffEitherEnd() {
        let spy = SpyInjector()
        spy.showOptions(["Yes", "No"], selected: 0)
        spy.sendArrowUp()
        XCTAssertEqual(spy.selected, 0)
        spy.sendArrowDown()
        spy.sendArrowDown()
        XCTAssertEqual(spy.selected, 1)
    }

    /// The case `SessionStore.choose` has to survive: a TUI that took the keystroke and did
    /// not move. The event is still recorded — the driver did press the key — but the
    /// selection did not follow, so the screen re-read afterwards shows the old row and the
    /// confirmation pass must refuse Return.
    func testAnIgnoredArrowIsStillRecordedButMovesNothing() {
        let spy = SpyInjector()
        spy.showOptions(["a", "b", "c"], selected: 0)
        spy.ignoreArrowsAfter = 1
        spy.sendArrowDown()
        spy.sendArrowDown()
        XCTAssertEqual(spy.events, [.arrow(1), .arrow(1)])
        XCTAssertEqual(spy.selected, 1, "the second arrow was swallowed, so one row, not two")
    }

    func testTheOrderOfEveryEventIsRecorded() {
        let spy = SpyInjector()
        spy.showOptions(["a", "b"], selected: 0)
        spy.sendArrowDown()
        spy.sendReturn()
        XCTAssertEqual(spy.events, [.arrow(1), .ret])
    }

    func testEscapeIsItsOwnEventAndMovesNothing() {
        let spy = SpyInjector()
        spy.showOptions(["a", "b"], selected: 1)
        spy.sendEscape()
        XCTAssertEqual(spy.events, [.escape])
        XCTAssertEqual(spy.selected, 1, "escape is a refusal, not a movement")
    }

    /// An arrow that lands on a tab with no dialog up records the keystroke and nothing else.
    /// The fake must not invent a selection out of an empty list: `SessionStore.choose` reads
    /// the screen before it moves precisely so this never arises, and a fake that quietly
    /// moved anyway would hide that check failing.
    func testAnArrowWithNoDialogOnScreenMovesNothing() throws {
        let spy = SpyInjector()
        spy.typeDraft(["some draft"])
        spy.sendArrowDown()
        XCTAssertEqual(spy.events, [.arrow(1)])
        XCTAssertEqual(spy.selected, 0)
        XCTAssertEqual(
            InputBar.read(fromViewport: try XCTUnwrap(spy.readViewport()))?.content, "some draft"
        )
    }

    /// A tab showing the input bar rather than a dialog must still render as it always did —
    /// every rename and typed-prompt test in the suite reads that shape.
    func testAnInjectorWithNoOptionsStillDrawsTheInputBar() throws {
        let spy = SpyInjector()
        spy.typeDraft(["some draft"])
        let viewport = try XCTUnwrap(spy.readViewport())
        XCTAssertEqual(InputBar.read(fromViewport: viewport)?.content, "some draft")
        XCTAssertNil(
            markedOption(in: viewport),
            "the bar's own ❯ must not read as a dialog's focused row"
        )
    }

    /// Which numbered option the screen marks, read the way a parser has to read it: skip the
    /// indent, require `❯`, then require a number — because the input bar's own `❯` is exactly
    /// the thing that must not be mistaken for a dialog's focused row.
    ///
    /// Deliberately not `ChoiceDialog.locate`: that is Task 4's, is written against the
    /// captured fixtures rather than against this fake, and does not exist yet. Keeping the
    /// reader here means these tests prove the fake and Task 4's prove the parser, with
    /// neither able to pass by agreeing with the other's bug.
    private func markedOption(in viewport: String) -> (index: Int, label: String)? {
        for line in viewport.split(separator: "\n", omittingEmptySubsequences: false) {
            let row = line.drop { $0 == " " }
            guard row.hasPrefix("❯ ") else { continue }
            let rest = row.dropFirst(2)
            guard let dot = rest.firstIndex(of: "."),
                  let number = Int(rest[..<dot]) else { continue }
            let label = rest[rest.index(after: dot)...]
                .trimmingCharacters(in: .whitespaces)
            return (number - 1, label)
        }
        return nil
    }
}
