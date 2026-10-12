import Foundation
import XCTest
@testable import HostKit

/// The clock is read from a `@Sendable` closure, so a test's mutable "now" lives in a box.
private final class Clock: @unchecked Sendable {
    var now: Date
    init(_ now: Date) { self.now = now }
}

final class IdleTrackerTests: XCTestCase {
    func testIdleSinceTracksLastActivity() {
        let clock = Clock(Date(timeIntervalSince1970: 100))
        let t = IdleTracker(now: { clock.now })
        XCTAssertEqual(t.idleSince, Date(timeIntervalSince1970: 100))
        clock.now += 10; let a = t.begin()
        XCTAssertNil(t.idleSince)
        clock.now += 50; let b = t.begin(); t.end(a)
        XCTAssertNil(t.idleSince, "one activity still open")
        clock.now += 5; t.end(b)
        XCTAssertEqual(t.idleSince, Date(timeIntervalSince1970: 165))
        clock.now += 20; t.touch()
        XCTAssertEqual(t.idleSince, Date(timeIntervalSince1970: 185))
    }

    func testEndingUnknownTokenIsHarmless() {
        let t = IdleTracker(); t.end(UUID()); XCTAssertNotNil(t.idleSince)
    }

    /// An `end` that arrives twice (a run's watcher and a shutdown racing) must not move the
    /// clock: only the end that closed an open activity is one.
    func testEndingTwiceDoesNotMoveTheClock() {
        let clock = Clock(Date(timeIntervalSince1970: 100))
        let t = IdleTracker(now: { clock.now })
        let a = t.begin()
        clock.now += 5; t.end(a)
        clock.now += 30; t.end(a)
        XCTAssertEqual(t.idleSince, Date(timeIntervalSince1970: 105))
    }
}
