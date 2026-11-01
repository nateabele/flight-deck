import XCTest
@testable import FleetKit

/// What the phone shows between tapping Send and the agent's own transcript agreeing.
final class PromptOutboxTests: XCTestCase {
    private func turn(_ id: String, _ text: String) -> TimelineItem {
        TimelineItem(id: id, kind: .userTurn, status: .complete, body: .init(text: text))
    }

    private func assistant(_ id: String, _ text: String) -> TimelineItem {
        TimelineItem(id: id, kind: .assistantText, status: .complete, body: .init(text: text))
    }

    /// **The fixture that distinguishes.** The conversation ALREADY holds a "yes", so an
    /// implementation matching on text alone retires the entry on the very first reconcile —
    /// before the Mac has read the frame. Only a turn that was not there when the entry was
    /// filed can retire it.
    func testAnEntryIsRetiredOnlyByATurnThatWasNotAlreadyThere() {
        let existing = [turn("10#0", "yes")]
        var outbox = PromptOutbox()
        let token = UUID()
        outbox.add(id: token, text: "yes", alreadyShowing: existing)
        outbox.accept(token)

        outbox.reconcile(with: existing)
        XCTAssertEqual(outbox.entries.map(\.id), [token],
                       "a turn that predates the send confirms nothing")

        outbox.reconcile(with: existing + [turn("90#0", "yes")])
        XCTAssertTrue(outbox.entries.isEmpty)
    }

    /// One arriving turn retires at most one entry. Sending the same word twice is two
    /// messages and two turns are coming; clearing both on the first would erase a message
    /// the Mac has not typed yet.
    func testTwoIdenticalMessagesNeedTwoTurns() {
        var outbox = PromptOutbox()
        let first = UUID(), second = UUID()
        outbox.add(id: first, text: "yes", alreadyShowing: [])
        outbox.accept(first)
        outbox.add(id: second, text: "yes", alreadyShowing: [])
        outbox.accept(second)

        outbox.reconcile(with: [turn("10#0", "yes")])
        XCTAssertEqual(outbox.entries.map(\.id), [second], "in send order, oldest retired first")

        outbox.reconcile(with: [turn("10#0", "yes"), turn("50#0", "yes")])
        XCTAssertTrue(outbox.entries.isEmpty)
    }

    /// A prompt whose ack was lost but whose text landed anyway must clear itself, not sit
    /// there accusing the Mac. This is the case the fifteen-second deadline creates and it
    /// is the reason reconcile does not look at `state`.
    func testAFailedEntryIsRetiredWhenItsTurnTurnsUpAfterAll() {
        var outbox = PromptOutbox()
        let token = UUID()
        outbox.add(id: token, text: "ship it", alreadyShowing: [])
        outbox.fail(token, "Your Mac didn't confirm this.")

        outbox.reconcile(with: [turn("10#0", "ship it")])
        XCTAssertTrue(outbox.entries.isEmpty)
    }

    /// The agent quoting the message back is not the message landing.
    func testAssistantTextWithTheSameWordsConfirmsNothing() {
        var outbox = PromptOutbox()
        let token = UUID()
        outbox.add(id: token, text: "ship it", alreadyShowing: [])
        outbox.accept(token)

        outbox.reconcile(with: [assistant("10#0", "ship it")])
        XCTAssertEqual(outbox.entries.map(\.id), [token])
    }

    func testFailingAnEntryKeepsItVisibleWithItsReason() {
        var outbox = PromptOutbox()
        let token = UUID()
        outbox.add(id: token, text: "ship it", alreadyShowing: [])
        outbox.fail(token, "Not connected to your Mac, so this wasn't sent.")
        XCTAssertEqual(outbox.entries.first?.state,
                       .failed("Not connected to your Mac, so this wasn't sent."))
    }

    func testDismissingAFailedEntryRemovesIt() {
        var outbox = PromptOutbox()
        let token = UUID()
        outbox.add(id: token, text: "ship it", alreadyShowing: [])
        outbox.fail(token, "nope")
        outbox.dismiss(token)
        XCTAssertTrue(outbox.entries.isEmpty)
    }

    /// Drives the composer's Send button. One entry in flight at a time is what stops a
    /// double-tap becoming two messages.
    func testIsSendingReportsOnlyTheUnansweredOnes() {
        var outbox = PromptOutbox()
        let token = UUID()
        outbox.add(id: token, text: "ship it", alreadyShowing: [])
        XCTAssertTrue(outbox.isSending)
        outbox.accept(token)
        XCTAssertFalse(outbox.isSending)
    }

    func testAcceptingAndFailingAnUnknownTokenDoNothing() {
        var outbox = PromptOutbox()
        outbox.accept(UUID())
        outbox.fail(UUID(), "nope")
        XCTAssertTrue(outbox.entries.isEmpty)
    }
}
