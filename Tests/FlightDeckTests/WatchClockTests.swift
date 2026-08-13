import XCTest
@testable import FlightDeck

/// Drives `fire()` directly rather than waiting on the real timer — see that method's
/// note. The cadence itself is asserted through `interval(forActive:)`, which is the only
/// part of scheduling that carries a decision rather than plumbing.
@MainActor
final class WatchClockTests: XCTestCase {
    /// Stand-in for a watcher: something the clock can hold weakly and tick.
    private final class Subscriber {
        var ticks = 0
    }

    func testTicksARegisteredSubscriber() {
        let clock = WatchClock(appIsActive: { true })
        let sub = Subscriber()
        clock.add(sub) { sub.ticks += 1 }

        clock.fire()
        clock.fire()

        XCTAssertEqual(sub.ticks, 2)
    }

    func testRemoveStopsTicking() {
        let clock = WatchClock(appIsActive: { true })
        let sub = Subscriber()
        clock.add(sub) { sub.ticks += 1 }

        clock.fire()
        clock.remove(sub)
        clock.fire()

        XCTAssertEqual(sub.ticks, 1, "a removed subscriber must not be ticked again")
    }

    /// A watcher restarted in place must not end up polled twice per beat — the failure
    /// mode this replaces is two reads racing over one file offset.
    func testReRegisteringTheSameOwnerReplacesItsTick() {
        let clock = WatchClock(appIsActive: { true })
        let sub = Subscriber()
        clock.add(sub) { sub.ticks += 1 }
        clock.add(sub) { sub.ticks += 1 }

        clock.fire()

        XCTAssertEqual(sub.ticks, 1)
    }

    func testSubscribersAreTickedInRegistrationOrder() {
        let clock = WatchClock(appIsActive: { true })
        let first = Subscriber()
        let second = Subscriber()
        var order: [String] = []
        clock.add(first) { order.append("first") }
        clock.add(second) { order.append("second") }

        clock.fire()

        XCTAssertEqual(order, ["first", "second"])
    }

    /// The property each watcher used to get for free by cancelling its own timer in
    /// `deinit`: dropping a watcher without calling `stop()` must not leave the clock
    /// ticking a dead entry forever.
    func testDroppedOwnerIsPrunedWithoutStop() {
        let clock = WatchClock(appIsActive: { true })
        var ticks = 0
        do {
            let sub = Subscriber()
            clock.add(sub) { ticks += 1 }
            clock.fire()
            XCTAssertEqual(ticks, 1)
        }

        clock.fire()

        XCTAssertEqual(ticks, 1, "a deallocated owner's tick must not run")
    }

    func testBacksOffWhenTheAppIsNotFrontmost() {
        XCTAssertEqual(WatchClock.interval(forActive: true), WatchClock.foregroundInterval)
        XCTAssertEqual(WatchClock.interval(forActive: false), WatchClock.backgroundInterval)
        XCTAssertLessThan(
            WatchClock.foregroundInterval, WatchClock.backgroundInterval,
            "the background cadence must be the slower of the two"
        )
    }

    /// Notifications are a background-only feature (`SessionNotificationPolicy` returns
    /// `.notify` only when the app is inactive), so the background cadence must stay a
    /// throttle rather than becoming a suspension. The ceiling is the notification latency
    /// a blocked agent can tolerate before the banner feels broken.
    func testBackgroundCadenceStaysPromptEnoughForNotifications() {
        XCTAssertLessThanOrEqual(
            WatchClock.backgroundInterval, .seconds(5),
            "background polling is what delivers session notifications; it must not stall"
        )
    }
}
