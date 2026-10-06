import XCTest
@testable import FlightDeck

/// "Active 4 min ago" on a row and in the drawer, and the stall clock contested detection leans
/// on (Task 11e). Stamped in `commitStatuses`, the one funnel every status write goes through, so
/// claude's registry tick and codex's runtime events stamp it the same way.
@MainActor
final class LastActiveAtTests: XCTestCase {
    func testEveryActivityTransitionStampsTheTab() {
        let store = SessionStore(provider: nil, persistence: nil)
        var clock = Date(timeIntervalSince1970: 1_790_000_000)
        store.now = { clock }
        let s = store.newSession(in: URL(fileURLWithPath: "/tmp/p", isDirectory: true))
        XCTAssertNil(store.lastActiveAt(for: s.id))

        store.applyRegistryForTesting([s.id: SessionStatus(activity: .busy)])
        XCTAssertEqual(store.lastActiveAt(for: s.id), clock)

        clock += 60
        store.applyRegistryForTesting([s.id: SessionStatus(activity: .busy, waitingFor: nil, subagentCount: 0)])
        XCTAssertEqual(store.lastActiveAt(for: s.id), clock - 60, "no transition, no stamp")

        clock += 60
        store.applyRegistryForTesting([s.id: SessionStatus(activity: .idle)])
        XCTAssertEqual(store.lastActiveAt(for: s.id), clock)
    }

    func testClosingTheTabForgetsIt() {
        let store = SessionStore(provider: nil, persistence: nil)
        let s = store.newSession(in: URL(fileURLWithPath: "/tmp/p", isDirectory: true))
        store.applyRegistryForTesting([s.id: SessionStatus(activity: .busy)])
        store.closeSession(s.id)
        XCTAssertNil(store.lastActiveAt(for: s.id))
    }

    /// Deviation 2 (ruling R23): the stamp lives beside `SessionStatus`, never inside it, so time
    /// passing on an unchanged tick publishes nothing. Inside it, every tick would invalidate the
    /// sidebar and replicate to the phone.
    func testAnUnchangedTickPublishesNoStatusesChangeAsTheClockAdvances() {
        let store = SessionStore(provider: nil, persistence: nil)
        var clock = Date(timeIntervalSince1970: 1_790_000_000)
        store.now = { clock }
        let s = store.newSession(in: URL(fileURLWithPath: "/tmp/p", isDirectory: true))
        store.applyRegistryForTesting([s.id: SessionStatus(activity: .busy)])
        var published = 0
        let sink = store.$statuses.dropFirst().sink { _ in published += 1 }
        clock += 600
        store.applyRegistryForTesting([s.id: SessionStatus(activity: .busy)])
        XCTAssertEqual(published, 0)
        sink.cancel()
    }
}
