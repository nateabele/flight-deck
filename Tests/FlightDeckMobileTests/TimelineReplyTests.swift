import FleetKit
import XCTest
@testable import FlightDeckMobile

/// A stand-in for the wire. Reply never touches it — the whole point of the arithmetic below is
/// that it happens in the box, before anything is sent — but the model will not build without
/// one.
@MainActor
private final class SilentFleet: TimelinePaging, PromptSending, PromptAnswering, PresenceReporting {
    func viewing(_ session: UUID?) {}
    func markRead(_ id: UUID) {}
    func timelinePage(
        _ request: FleetRequest,
        then completion: @escaping (Result<TimelinePage, FleetRequestError>) -> Void
    ) {}
    func sendPrompt(
        _ command: FleetCommand,
        then completion: @escaping (Result<Void, FleetRequestError>) -> Void
    ) {}
    func answerPrompt(
        _ command: FleetCommand,
        then completion: @escaping (Result<Void, FleetRequestError>) -> Void
    ) {}
}

/// What Reply puts in the box.
///
/// **The selection itself is not reachable from here**, and nothing below pretends otherwise: a
/// `UITextView`'s edit menu, the range it hands back, and whether Reply sits where a thumb
/// expects it are all things with no window in this process — docs/MOBILE.md's checklist owns
/// them. What *is* reachable is the part that would be wrong in a way nobody notices: the
/// quotation's shape, and the draft it is appended to.
@MainActor
final class TimelineReplyTests: XCTestCase {

    private func model() -> SessionTimelineModel {
        SessionTimelineModel(sessionID: UUID(), fleet: SilentFleet())
    }

    func testAQuotationIsPrefixedAndFollowedByABlankLine() {
        let model = model()
        model.quote("the queue drains first")
        XCTAssertEqual(model.draft, "> the queue drains first\n\n")
    }

    /// **Every line, not just the first.** A two-line quotation with one marker is a quotation
    /// and a stray sentence, and on the receiving end it reads as the reader having said the
    /// second line themselves.
    func testEveryLineOfAMultiLineSelectionIsPrefixed() {
        let model = model()
        model.quote("drain the queue\nflip the flag")
        XCTAssertEqual(model.draft, "> drain the queue\n> flip the flag\n\n")
    }

    /// A blank line inside a quotation stays blank rather than becoming a marker with a
    /// trailing space — `"> "` on an empty line is whitespace nobody typed.
    func testABlankLineInsideASelectionKeepsItsMarkerBare() {
        let model = model()
        model.quote("drain the queue\n\nflip the flag")
        XCTAssertEqual(model.draft, "> drain the queue\n>\n> flip the flag\n\n")
    }

    /// **It appends.** Someone half way through writing a message who highlights a sentence has
    /// not asked for what they wrote to be thrown away.
    func testAQuotationIsAppendedToWhatIsAlreadyThere() {
        let model = model()
        model.draft = "about this"
        model.quote("the queue drains first")
        XCTAssertEqual(model.draft, "about this\n> the queue drains first\n\n")
    }

    /// And two quotations stack, which is what a second Reply means.
    func testASecondReplyStacksUnderTheFirst() {
        let model = model()
        model.quote("first point")
        model.quote("second point")
        XCTAssertEqual(model.draft, "> first point\n\n> second point\n\n")
        XCTAssertEqual(model.quoteTicks, 2, "the composer takes focus once per quotation")
    }

    /// The draft already ends on a newline, so no separator is added — the alternative leaves a
    /// blank line the writer did not put there and cannot see the reason for.
    func testNoSeparatorIsAddedToADraftAlreadyEndingInANewline() {
        let model = model()
        model.draft = "about this\n"
        model.quote("the queue drains first")
        XCTAssertEqual(model.draft, "about this\n> the queue drains first\n\n")
    }

    /// A drag that caught only a paragraph break can raise the menu on whitespace. Quoting it
    /// would put two bare markers in the box for no reason.
    func testAWhitespaceOnlySelectionIsDropped() {
        let model = model()
        model.quote("  \n \n")
        XCTAssertEqual(model.draft, "")
        XCTAssertEqual(model.quoteTicks, 0, "nothing happened, so the field must not grab focus")
    }

    /// The outbox matches a sent prompt on **exact string equality** (`PromptOutbox.reconcile`),
    /// so anything that rewrote the draft on its way out would leave the sent row un-retired.
    /// Quoting must therefore leave a draft that survives the round trip unchanged.
    func testAQuotedDraftIsSentVerbatim() {
        let model = model()
        model.quote("the queue drains first")
        model.draft += "why?"
        let sent = PromptText(model.draft)
        XCTAssertEqual(
            sent?.value, "> the queue drains first\n\nwhy?",
            "PromptText trims the ends and must not touch the quotation between them"
        )
    }
}
