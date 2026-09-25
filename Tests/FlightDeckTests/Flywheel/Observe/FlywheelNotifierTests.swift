import XCTest
@testable import FlightDeck

private final class SpyNotifier: Notifying {
    var notified: [(UUID, String)] = []
    func requestAuthorization() {}
    func notify(sessionID: UUID, title: String, subtitle: String, body: String) { notified.append((sessionID, title)) }
    func withdraw(sessionID: UUID) {}
}

// @MainActor: mirrors FlywheelObserveServiceTests — FlywheelNotifier is @MainActor, so its
// tests must share isolation to call `evaluate`/`route`/`init` synchronously.
@MainActor
final class FlywheelNotifierTests: XCTestCase {
    private func blockedProjection(_ name: String, since: Date) -> [String: FlywheelProjection] {
        var a = FlywheelProjection.Agent(name: name, bead: nil, status: .blocked, holds: [], waitsOn: [], lastEventAt: nil, stalledSince: since)
        return ["/tmp/p": FlywheelProjection(agents: [a], reservations: [], depEdges: [], beadsByID: [:], lanesUnavailable: [])]
    }

    func testTransientBlockDoesNotNotify() {
        let spy = SpyNotifier()
        var t = Date()
        let n = FlywheelNotifier(notifier: spy, blockThreshold: 120, now: { t })
        let id = UUID(); n.route = { _, _ in id }
        n.evaluate(projectsByKey: blockedProjection("BlueFalcon", since: t))   // just blocked
        t = t.addingTimeInterval(30)                                          // 30s < 120s
        n.evaluate(projectsByKey: blockedProjection("BlueFalcon", since: t.addingTimeInterval(-30)))
        XCTAssertTrue(spy.notified.isEmpty)
    }

    func testPersistentBlockNotifiesOnceCoalesced() {
        let spy = SpyNotifier()
        let start = Date(); var t = start
        let n = FlywheelNotifier(notifier: spy, blockThreshold: 120, now: { t })
        let id = UUID(); n.route = { _, _ in id }
        n.evaluate(projectsByKey: blockedProjection("BlueFalcon", since: start))
        t = start.addingTimeInterval(200)                                     // past threshold
        n.evaluate(projectsByKey: blockedProjection("BlueFalcon", since: start))
        n.evaluate(projectsByKey: blockedProjection("BlueFalcon", since: start))  // still blocked
        XCTAssertEqual(spy.notified.count, 1, "a standing block notifies once, not every tick")
    }

    func testCollisionWithActiveHolderIsSilentButStalledHolderNotifies() {
        let spy = SpyNotifier()
        let n = FlywheelNotifier(notifier: spy, blockThreshold: 120, now: { Date() })
        n.route = { _, _ in UUID() }
        func projection(holderStatus: AgentStatus) -> [String: FlywheelProjection] {
            let res = FlywheelProjection.Reservation(file: "a.swift", holder: "GoldViper", since: Date(), waiters: ["BlueFalcon"])
            let holder = FlywheelProjection.Agent(name: "GoldViper", bead: nil, status: holderStatus, holds: ["a.swift"], waitsOn: [], lastEventAt: nil, stalledSince: holderStatus == .stalled ? Date() : nil)
            let waiter = FlywheelProjection.Agent(name: "BlueFalcon", bead: nil, status: .blocked, holds: [], waitsOn: [res], lastEventAt: nil, stalledSince: nil)
            return ["/tmp/p": FlywheelProjection(agents: [holder, waiter], reservations: [res], depEdges: [], beadsByID: [:], lanesUnavailable: [])]
        }
        n.evaluate(projectsByKey: projection(holderStatus: .active))
        XCTAssertTrue(spy.notified.isEmpty, "an actively-worked collision is not a human's problem yet")
        n.evaluate(projectsByKey: projection(holderStatus: .stalled))
        XCTAssertEqual(spy.notified.count, 1, "a stalled holder blocking a waiter needs a human")
    }
}
