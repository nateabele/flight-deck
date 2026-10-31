import XCTest
@testable import HostKit

final class SessionBudgetModelTests: XCTestCase {
    typealias M = SessionBudgetModel
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    func at(_ hours: Double) -> Date { now.addingTimeInterval(hours * 3600) }

    func testNothingLeftIsExhaustedNow() {
        XCTAssertEqual(M.exhaustion(remaining: 0, burns: [.init(hourlyUSD: 1, until: at(5))], now: now), now)
        XCTAssertEqual(M.exhaustion(remaining: -2, burns: [], now: now), now)
    }

    func testNoBurnNeverExhausts() {
        XCTAssertNil(M.exhaustion(remaining: 5, burns: [], now: now))
        // A machine already past its deadline bills nothing more.
        XCTAssertNil(M.exhaustion(remaining: 5, burns: [.init(hourlyUSD: 3, until: at(-1))], now: now))
    }

    func testOneMachineRunsOutAtRemainingOverRate() throws {
        let end = try XCTUnwrap(M.exhaustion(remaining: 2, burns: [.init(hourlyUSD: 0.8, until: at(4))], now: now))
        XCTAssertEqual(end.timeIntervalSince(now), 2.5 * 3600, accuracy: 1e-6)
    }

    func testDeadlineFirstMeansNeverExhausted() {
        // $0.80 for 2h is $1.60, under the $2 left.
        XCTAssertNil(M.exhaustion(remaining: 2, burns: [.init(hourlyUSD: 0.8, until: at(2))], now: now))
    }

    func testRateFallsAsMachinesReachTheirDeadlines() throws {
        // $2/h + $1/h for the first hour ($3), then $1/h alone: $5 runs out 2h later, at 3h.
        let end = try XCTUnwrap(M.exhaustion(remaining: 5, burns: [.init(hourlyUSD: 2, until: at(1)), .init(hourlyUSD: 1, until: at(10))], now: now))
        XCTAssertEqual(end.timeIntervalSince(now), 3 * 3600, accuracy: 1e-6)
    }

    func testLaunchRefusedWhenUsedUp() {
        guard case .refused(let why) = M.checkLaunch(name: "gpu", hourly: 1, ttlDeadline: at(4), remaining: 0, capUSD: 5, burns: [], now: now)
        else { return XCTFail() }
        XCTAssertTrue(why.contains("used up") && why.contains("$5.00"), why)
    }

    func testLaunchRefusedWhenUnpriced() {
        guard case .refused(let why) = M.checkLaunch(name: "gpu", hourly: nil, ttlDeadline: at(4), remaining: 5, capUSD: 5, burns: [], now: now)
        else { return XCTFail() }
        XCTAssertTrue(why.contains("max_hourly"), why)
    }

    func testLaunchKeepsItsTTLWhenTheBudgetOutlastsIt() {
        XCTAssertEqual(M.checkLaunch(name: "gpu", hourly: 1, ttlDeadline: at(4), remaining: 5, capUSD: 5, burns: [], now: now),
                       .allowed(deadline: at(4)))
    }

    func testLaunchDeadlineIsClampedToExhaustion() {
        // $3 left at $1/h with another $1/h machine running all day: 1.5h.
        XCTAssertEqual(M.checkLaunch(name: "gpu", hourly: 1, ttlDeadline: at(4), remaining: 3, capUSD: 10,
                                     burns: [.init(hourlyUSD: 1, until: at(24))], now: now),
                       .allowed(deadline: at(1.5)))
    }

    func testLaunchRefusedBelowMinimumLife() {
        // $0.20 at $1/h is 12 minutes, under the 15-minute floor.
        guard case .refused(let why) = M.checkLaunch(name: "gpu", hourly: 1, ttlDeadline: at(4), remaining: 0.2, capUSD: 5, burns: [], now: now)
        else { return XCTFail() }
        XCTAssertTrue(why.contains("12 minutes"), why)
        XCTAssertEqual(M.checkLaunch(name: "gpu", hourly: 1, ttlDeadline: at(4), remaining: 0.25, capUSD: 5, burns: [], now: now),
                       .allowed(deadline: at(0.25)))
    }
}
