import FleetKit
import XCTest
@testable import FlightDeckMobile

/// The card's decisions, extracted from the view so they can be asserted without a render —
/// the same shape `PromptComposerTests` uses, and for the same reason.
@MainActor
final class PromptCardTests: XCTestCase {
    private func question(unanswerable: String? = nil) -> OpenPrompt {
        .question(callID: "toolu_A", PromptQuestion(
            header: "Pick", question: "Which?",
            options: [.init(label: "Yes"), .init(label: "No")], unanswerable: unanswerable
        ))
    }

    private let permission = OpenPrompt.permission(
        callID: "toolu_B", tool: "Bash", summary: "rm -rf build"
    )

    /// **Controls in exactly one state.** `sent` must not offer them — tapping twice answers
    /// twice — and `failed` must not either, because a Return may already be on its way.
    func testControlsAreOfferedOnlyBeforeAnAnswerIsSent() {
        XCTAssertTrue(PromptCard.showsControls(for: question(), state: .idle))
        XCTAssertFalse(PromptCard.showsControls(for: question(), state: .sent(call: "toolu_A")))
        XCTAssertFalse(
            PromptCard.showsControls(for: question(), state: .failed(call: "toolu_A", "nope"))
        )
    }

    /// A state left over from a PREVIOUS dialog must not suppress this one's controls — the
    /// harder race, seen from the phone: the session never left `waiting`, so the card was
    /// never torn down, and a failure filed against `toolu_ONE` would silently disable the
    /// buttons for `toolu_TWO`. Keyed on the call for exactly that reason.
    func testAStateFromADifferentCallDoesNotSuppressThisOnesControls() {
        XCTAssertTrue(
            PromptCard.showsControls(for: question(), state: .sent(call: "toolu_OTHER"))
        )
        XCTAssertTrue(
            PromptCard.showsControls(for: question(), state: .failed(call: "toolu_OTHER", "no"))
        )
    }

    /// And it must not put the previous dialog's footnote under this one's question either: a
    /// card reading "Sent to your Mac." over a question nobody has answered is a reader told
    /// their tap landed on something they never saw.
    func testAFootnoteFromADifferentCallIsNotShownUnderThisOne() {
        XCTAssertNil(PromptCard.footnote(for: question(), state: .sent(call: "toolu_OTHER")))
        XCTAssertNil(
            PromptCard.footnote(for: question(), state: .failed(call: "toolu_OTHER", "Moved on."))
        )
    }

    func testAnUnanswerableQuestionShowsItsReasonAndNoControls() {
        let multi = question(unanswerable: PromptQuestion.multiSelectReason)
        XCTAssertFalse(PromptCard.showsControls(for: multi, state: .idle))
        XCTAssertEqual(
            PromptCard.footnote(for: multi, state: .idle), PromptQuestion.multiSelectReason
        )
    }

    /// A permission card always has controls, because Allow and Deny do not come from a payload
    /// — they are the two intents `PromptAnswer` names. There is nothing to be unanswerable
    /// about.
    func testAPermissionCardAlwaysHasControls() {
        XCTAssertTrue(PromptCard.showsControls(for: permission, state: .idle))
        XCTAssertNil(PromptCard.footnote(for: permission, state: .idle))
    }

    func testASentAnswerSaysSoRatherThanSayingNothing() {
        XCTAssertEqual(
            PromptCard.footnote(for: question(), state: .sent(call: "toolu_A")),
            PromptCard.sentFootnote
        )
    }

    func testAFailureShowsTheMacsOwnReason() {
        XCTAssertEqual(
            PromptCard.footnote(for: question(), state: .failed(call: "toolu_A", "Moved on.")),
            "Moved on."
        )
    }

    /// A permission card names the tool and shows its command, which is more than the terminal
    /// shows — and it is all the phone has, because the dialog's own wording exists nowhere it
    /// can read.
    func testAPermissionCardIsTitledFromTheToolAndItsSummary() {
        XCTAssertEqual(PromptCard.title(for: permission), "Claude wants to run Bash")
        XCTAssertEqual(PromptCard.subtitle(for: permission), "rm -rf build")
    }

    func testAPermissionCardForAToolWithNoSummaryStillHasATitle() {
        XCTAssertEqual(
            PromptCard.title(for: .permission(callID: "x", tool: nil, summary: nil)),
            "Claude is waiting for you"
        )
        XCTAssertNil(PromptCard.subtitle(for: .permission(callID: "x", tool: nil, summary: nil)))
    }

    /// A question's own words are its title, and it has no second line: an option's meaning
    /// lives in that option's description, not above the list.
    func testAQuestionIsTitledWithTheQuestionAndHasNoSubtitle() {
        XCTAssertEqual(PromptCard.title(for: question()), "Which?")
        XCTAssertNil(PromptCard.subtitle(for: question()))
    }

    /// A historical row rebuilds its question with the same parser the live card uses. A body
    /// the parser refuses — a truncated one — falls back to the raw text rather than nothing.
    func testAHistoricalRowRebuildsItsQuestionFromTheBody() throws {
        let body = #"{"questions":[{"question":"Which?","options":[{"label":"a"}]}]}"#
        XCTAssertEqual(try XCTUnwrap(PromptQuestion(toolInput: body)).question, "Which?")
        XCTAssertNil(PromptQuestion(toolInput: String(body.prefix(20))))
    }
}
