import FleetKit
import XCTest
@testable import FlightDeckMobile

/// What the phone shows for an ask it has sent but the Mac's projection does not list yet, and
/// which Mac versions it may ask at all.
final class ThreadOutboxTests: XCTestCase {
    private func draft(thread: UUID? = nil, text: String = "Why Friday?") -> ThreadDraft {
        ThreadDraft(threadID: thread, anchor: WireThreadAnchor(checkpoint: 3, block: 4, quote: "ship on Friday"), text: text)
    }

    private func summary(_ id: UUID, turns: Int = 0) -> WireThreadSummary {
        WireThreadSummary(id: id, title: "t", status: "open", counts: WireThreadCounts(turns: turns))
    }

    // MARK: - New threads

    /// The Mac names a phone-opened thread by the send's token (`ThreadID.opened(byToken:)`), so
    /// the outbox can show it under that id the moment the ack lands.
    func testAnAckedNewThreadIsListedUnderItsTokenUntilTheMacListsIt() {
        var outbox = ThreadOutbox()
        let d = draft(), token = UUID()
        outbox.submit(d)
        outbox.sending(d.id, token: token)
        XCTAssertEqual(outbox.listing([]).count, 0, "unacked: drawn as unsent, not as a thread")
        XCTAssertEqual(outbox.unsent, [d])

        outbox.acked(d.id)
        XCTAssertTrue(outbox.unsent.isEmpty)
        let shown = outbox.listing([])
        XCTAssertEqual(shown.map(\.id), [token])
        XCTAssertEqual(shown.first?.title, "Why Friday?")
        XCTAssertEqual(shown.first?.status, "answering")
        XCTAssertEqual(shown.first?.anchor?.block, 4)
        XCTAssertEqual(outbox.openedThread(of: d.id), token)

        // Once the Mac lists it (with its first turn), the Mac's summary is the record.
        outbox.reconcile(threads: [summary(token, turns: 1)])
        XCTAssertEqual(outbox.listing([summary(token, turns: 1)]).count, 1)
        XCTAssertNil(outbox.openedThread(of: d.id))
    }

    /// A retry after a timeout keeps the token (IntakeCommandModel), so the id the outbox shows
    /// never changes; a fresh press mints a new one and the outbox follows it.
    func testTheLatestSendTokenIsTheOneShown() {
        var outbox = ThreadOutbox()
        let d = draft(), first = UUID(), second = UUID()
        outbox.submit(d)
        outbox.sending(d.id, token: first)
        outbox.sending(d.id, token: second)
        outbox.acked(d.id)
        XCTAssertEqual(outbox.listing([]).map(\.id), [second])
    }

    func testAListedThreadIsNeverShownTwice() {
        var outbox = ThreadOutbox()
        let d = draft(), token = UUID()
        outbox.submit(d); outbox.sending(d.id, token: token); outbox.acked(d.id)
        XCTAssertEqual(outbox.listing([summary(token)]).count, 1)
    }

    // MARK: - Replies

    func testAReplyShowsAsPendingUntilTheThreadsTurnsHoldItsMessage() {
        var outbox = ThreadOutbox()
        let thread = UUID(), d = draft(thread: thread, text: "And Monday?"), token = UUID()
        outbox.submit(d); outbox.sending(d.id, token: token); outbox.acked(d.id)
        XCTAssertEqual(outbox.pendingMessages(in: thread).map(\.text), ["And Monday?"])
        XCTAssertTrue(outbox.pendingMessages(in: UUID()).isEmpty)

        outbox.reconcile(thread: thread, turns: [WireThreadTurn(seq: 1, messageID: "other", checkpoint: 3, startedAt: Date())])
        XCTAssertEqual(outbox.pendingMessages(in: thread).count, 1)
        outbox.reconcile(thread: thread, turns: [WireThreadTurn(seq: 2, messageID: token.uuidString, checkpoint: 3, startedAt: Date())])
        XCTAssertTrue(outbox.pendingMessages(in: thread).isEmpty)
    }

    /// The first message of a phone-opened thread has the token as its messageID too, so the
    /// thread screen of a just-opened thread shows it pending in the same way.
    func testAnOpeningMessageIsPendingInItsNewThread() {
        var outbox = ThreadOutbox()
        let d = draft(), token = UUID()
        outbox.submit(d); outbox.sending(d.id, token: token); outbox.acked(d.id)
        XCTAssertEqual(outbox.pendingMessages(in: token).map(\.text), ["Why Friday?"])
    }

    func testAFailedDraftStaysUnsentForARetryAndCanBeDiscarded() {
        var outbox = ThreadOutbox()
        let d = draft()
        outbox.submit(d)
        outbox.submit(d)
        XCTAssertEqual(outbox.unsent, [d], "a retry is the same draft")
        outbox.remove(d.id)
        XCTAssertTrue(outbox.unsent.isEmpty)
    }

    // MARK: - Diff decisions

    /// An accepted diff keeps drawing as its new text, and a rejected one as its old, until the
    /// plan stops listing it as pending: a runner applies the decision after the ack.
    func testADecisionHoldsUntilThePlanNoLongerListsTheDiffAsPending() {
        var outbox = ThreadOutbox()
        let diff = WirePendingDiff(id: UUID(), thread: UUID(), checkpoint: 3, blockIndex: 4, old: "a", new: "b", state: "pending")
        outbox.decided(diff.id, accept: true)
        XCTAssertEqual(outbox.decision(for: diff.id), true)
        outbox.reconcile(diffs: [diff])
        XCTAssertEqual(outbox.decision(for: diff.id), true, "still pending on the Mac")
        outbox.reconcile(diffs: [])
        XCTAssertNil(outbox.decision(for: diff.id))
    }

    // MARK: - Gate

    private func detail(threads: Bool?, steer: Bool? = true, state: String = "shaping") -> WireIntakeDetail {
        WireIntakeDetail(etag: "e", project: UUID(),
                         summary: WireIntakeSummary(id: UUID(), title: "t", state: state, needsAttention: false, createdAt: Date()),
                         intent: "i", servedAt: Date(), steer: steer, threads: threads)
    }

    /// Every thread op is gated on the Mac's `threads` flag: an older Mac drops the socket on an
    /// op it does not know.
    func testNothingIsOfferedWithoutTheThreadsFlag() {
        XCTAssertFalse(ThreadGate.canRead(detail: nil))
        XCTAssertFalse(ThreadGate.canRead(detail: detail(threads: nil)))
        XCTAssertFalse(ThreadGate.canRead(detail: detail(threads: false)))
        XCTAssertFalse(ThreadGate.canAsk(detail: detail(threads: nil)))
        XCTAssertFalse(ThreadGate.canAsk(detail: detail(threads: false)))
        XCTAssertTrue(ThreadGate.canRead(detail: detail(threads: true)))
        XCTAssertTrue(ThreadGate.canAsk(detail: detail(threads: true)))
    }

    /// Reading a thread needs only the flag; asking and deciding also need an intake still shaping.
    func testAskingNeedsAShapingIntakeButReadingDoesNot() {
        let moved = detail(threads: true, state: "review")
        XCTAssertTrue(ThreadGate.canRead(detail: moved))
        XCTAssertFalse(ThreadGate.canAsk(detail: moved))
        XCTAssertFalse(ThreadGate.canAsk(detail: detail(threads: true, steer: false)))
    }

    func testTheReaderAsksOnlyAtTheHead() {
        XCTAssertTrue(ThreadGate.canAskInReader(detail: detail(threads: true), checkpoint: nil))
        XCTAssertFalse(ThreadGate.canAskInReader(detail: detail(threads: true), checkpoint: 2))
        XCTAssertFalse(ThreadGate.canAskInReader(detail: detail(threads: nil), checkpoint: nil))
    }
}
