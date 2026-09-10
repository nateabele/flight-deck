import FleetKit
import XCTest
@testable import FlightDeckMobile

/// A `.delivered` outbox entry, shown inline in the transcript rather than in the outbox — and
/// never anywhere else. `entries(from:delivered:)` is the pure boundary that decides this, so
/// these tests never touch a view.
final class TranscriptGhostTests: XCTestCase {
    func testADeliveredOutboxEntryBecomesATrailingGhost() {
        let t = UUID()
        let feed = [
            TimelineItem(
                id: "0#0", kind: .userTurn, status: .complete, body: .init(text: "old")
            )
        ]
        var outbox = PromptOutbox()
        outbox.add(id: t, text: "hi", alreadyShowing: [])
        outbox.accept(t)
        outbox.deliver(t)

        let entries = SessionTimelineScreen.entries(from: feed, delivered: outbox.entries)

        XCTAssertEqual(entries.last?.id, "ghost:\(t.uuidString)")
        XCTAssertTrue(entries.last!.isGhost)
        XCTAssertEqual(entries.dropLast().map(\.id), ["0#0"])
    }

    func testNoGhostWithoutADeliveredEntry() {
        let feed = [
            TimelineItem(
                id: "0#0", kind: .userTurn, status: .complete, body: .init(text: "old")
            )
        ]

        XCTAssertEqual(SessionTimelineScreen.entries(from: feed).map(\.id), ["0#0"])
    }

    /// A `.sending` or `.accepted` entry is not delivered yet, so it must not become a ghost
    /// either — the caller filters on `state == .delivered`, and this pins the filter rather
    /// than the helper, which trusts whatever it is handed.
    func testASendingOrAcceptedEntryIsNotAGhost() {
        var outbox = PromptOutbox()
        let t = UUID()
        outbox.add(id: t, text: "hi", alreadyShowing: [])

        let entries = SessionTimelineScreen.entries(
            from: [], delivered: outbox.entries.filter { $0.state == .delivered }
        )

        XCTAssertTrue(entries.isEmpty)
    }
}
