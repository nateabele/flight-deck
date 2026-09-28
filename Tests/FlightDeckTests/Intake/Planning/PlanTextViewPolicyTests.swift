import XCTest
@testable import FlightDeck

final class PlanTextViewPolicyTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    /// `commands.jsonl` never compacts, so an edit per keystroke would grow it by a whole plan
    /// per character typed. Commits wait for `EditPolicy.idle` seconds of quiet.
    func testCommitAfterIdleNotPerKeystroke() {
        var session = PlanEditSession(text: "# Plan")
        session.editing = true
        for (i, text) in ["# Plan!", "# Plan!!", "# Plan!!!"].enumerated() {
            session.type(text, at: t0.addingTimeInterval(Double(i) * 0.5))
            XCTAssertNil(session.commitIfIdle(now: t0.addingTimeInterval(Double(i) * 0.5 + 0.4)), "no commit per keystroke")
        }
        XCTAssertTrue(session.dirty)
        XCTAssertNil(session.commitIfIdle(now: t0.addingTimeInterval(1.0 + EditPolicy.idle - 0.01)), "not before the idle window")
        XCTAssertEqual(session.commitIfIdle(now: t0.addingTimeInterval(1.0 + EditPolicy.idle)), "# Plan!!!")
        XCTAssertFalse(session.dirty)
        XCTAssertNil(session.commitIfIdle(now: t0.addingTimeInterval(60)), "one commit per burst, not one per tick")

        // Ending the edit commits at once, without waiting out the window — and only if dirty.
        session.type("# Plan?", at: t0.addingTimeInterval(100))
        XCTAssertEqual(session.endEditing(), "# Plan?")
        XCTAssertNil(session.endEditing())
        XCTAssertFalse(session.editing)
    }

    /// Review Focus 3: a round landing while the human types must not swap the text out from
    /// under them. The head is held back (the banner offers it) and not one keystroke is lost.
    func testIncomingHeadDoesNotReplaceTextWhileEditing() {
        XCTAssertFalse(EditPolicy.shouldReplace(editing: true, dirty: true))
        var session = PlanEditSession(text: "# Plan")
        session.editing = true
        session.type("# Plan, edited", at: t0)
        XCTAssertFalse(session.offer("# Plan v2"))
        XCTAssertEqual(session.current, "# Plan, edited")
        XCTAssertEqual(session.held, "# Plan v2")
        XCTAssertTrue(session.dirty, "the typed text is still uncommitted, not overwritten")
    }

    func testIncomingHeadReplacesWhenIdleAndClean() {
        XCTAssertTrue(EditPolicy.shouldReplace(editing: false, dirty: false))
        XCTAssertTrue(EditPolicy.shouldReplace(editing: true, dirty: false), "focused but committed: nothing to lose")
        XCTAssertTrue(EditPolicy.shouldReplace(editing: false, dirty: true), "not focused: the edit is committed on the way out")
        var session = PlanEditSession(text: "# Plan")
        XCTAssertTrue(session.offer("# Plan v2"))
        XCTAssertEqual(session.current, "# Plan v2")
        XCTAssertNil(session.held)
        XCTAssertFalse(session.dirty)
    }
}
