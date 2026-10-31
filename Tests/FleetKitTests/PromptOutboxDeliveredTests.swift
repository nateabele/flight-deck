import XCTest
@testable import FleetKit

final class PromptOutboxDeliveredTests: XCTestCase {
    func testDeliverMovesAcceptedEntryToDelivered() {
        var outbox = PromptOutbox(); let t = UUID()
        outbox.add(id: t, text: "hi", alreadyShowing: []); outbox.accept(t); outbox.deliver(t)
        XCTAssertEqual(outbox.entries.first?.state, .delivered)
    }
    func testDeliverIsIdempotentAndSafeForUnknownToken() {
        var outbox = PromptOutbox()
        outbox.deliver(UUID())                                   // unknown → no-op
        let t = UUID(); outbox.add(id: t, text: "hi", alreadyShowing: [])
        outbox.deliver(t); outbox.deliver(t)                     // twice
        XCTAssertEqual(outbox.entries.filter { $0.state == .delivered }.count, 1)
    }
    func testReconcileDropsADeliveredEntryWhenTheTranscriptHoldsIt() {
        var outbox = PromptOutbox(); let t = UUID()
        outbox.add(id: t, text: "hi", alreadyShowing: []); outbox.deliver(t)
        let item = TimelineItem(id: "10#0", kind: .userTurn, status: .complete, body: .init(text: "hi"))
        outbox.reconcile(with: [item])
        XCTAssertTrue(outbox.entries.isEmpty)
    }
}
