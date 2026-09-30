import XCTest
@testable import FlightDeck

/// The text an agent actually reads when a plan is sent back from the phone.
///
/// **Plannotator's deny endpoint does not read its own annotation store.** `POST /api/deny`
/// hands `body.feedback` to the hook verbatim and falls back to `"Plan rejected by user"`; the
/// `# Plan Feedback` document an agent sees when "Send Feedback" is pressed in the browser is
/// built by the *browser*, client-side, from the annotations it holds. So a phone comment
/// posted to `/api/external-annotations` reached the gate, showed in its sidebar, and never
/// reached the agent — confirmed against a live `plannotator` 0.27.8 gate on 2026-09-30.
final class PlanFeedbackTests: XCTestCase {

    /// Byte-for-byte what the browser's "Send Feedback" posted to `/api/deny` for these two
    /// annotations — captured from a live 0.27.8 gate with a `fetch` hook. The agent has been
    /// trained on this shape by every browser review it has ever had; the phone should not
    /// invent a second one.
    func testMatchesWhatTheBrowserSends() {
        let text = PlanFeedback.compose(comments: [
            .init(text: "PINNED-PROBE: call it WidgetBuilder, not WidgetMaker",
                  originalText: "Rename the widget factory to WidgetMaker."),
            .init(text: "GLOBAL-PROBE: add tests before deleting anything", originalText: nil),
        ], note: nil)
        XCTAssertEqual(text, """
        # Plan Feedback

        I've reviewed this plan and have 2 pieces of feedback:

        ## 1. Feedback on: "Rename the widget factory to WidgetMaker."
        > PINNED-PROBE: call it WidgetBuilder, not WidgetMaker

        ## 2. General feedback about the plan
        > GLOBAL-PROBE: add tests before deleting anything

        ---

        """)
    }

    /// The footer note is one more general piece, last — the reader typed it after reading the
    /// whole plan, and numbering it keeps the agent's "address ALL of the feedback" instruction
    /// pointing at every item.
    func testTheNoteIsTheLastGeneralPiece() {
        let text = PlanFeedback.compose(
            comments: [.init(text: "wrong name", originalText: "Step one.")],
            note: "and split step two"
        )
        XCTAssertEqual(text, """
        # Plan Feedback

        I've reviewed this plan and have 2 pieces of feedback:

        ## 1. Feedback on: "Step one."
        > wrong name

        ## 2. General feedback about the plan
        > and split step two

        ---

        """)
    }

    /// Singular is the browser's own wording, and a note alone is still a document rather than
    /// a bare string — the agent reads one shape whatever the phone sent.
    func testASingleNoteAlone() {
        XCTAssertEqual(PlanFeedback.compose(comments: [], note: "not yet"), """
        # Plan Feedback

        I've reviewed this plan and have 1 piece of feedback:

        ## 1. General feedback about the plan
        > not yet

        ---

        """)
    }

    /// A multi-line comment stays inside its quote. Only the first line carrying `> ` would
    /// let the second read as the agent's own prose, or as a new heading if it starts with `#`.
    func testAMultiLineCommentStaysQuoted() {
        let text = PlanFeedback.compose(
            comments: [.init(text: "first\n# not a heading", originalText: nil)], note: nil
        )
        XCTAssertTrue(text?.contains("> first\n> # not a heading\n") == true, text ?? "nil")
    }

    /// Nothing to say is `nil`, so the caller sends no `feedback` key and Plannotator keeps its
    /// own default — rather than a document announcing zero pieces of feedback.
    func testNothingToSayIsNil() {
        XCTAssertNil(PlanFeedback.compose(comments: [], note: nil))
        XCTAssertNil(PlanFeedback.compose(comments: [], note: "  \n "))
    }
}
