import FleetKit
import XCTest
@testable import FlightDeckMobile

final class CloudStyleTests: XCTestCase {
    private let now = CloudFixtures.now

    func testMoneyKeepsAThirdDecimalOnlyForSubTenCentFigures() {
        XCTAssertEqual(CloudStyle.money(4.2), "$4.20")
        XCTAssertEqual(CloudStyle.money(0), "$0.00")
        XCTAssertEqual(CloudStyle.money(0.036), "$0.036")
        XCTAssertEqual(CloudStyle.rate(1.2), "$1.20/h")
        XCTAssertEqual(CloudStyle.rate(nil), "unpriced")
    }

    func testDurationAndCountdown() {
        XCTAssertEqual(CloudStyle.duration(2 * 3600 + 14 * 60 + 9), "2h 14m")
        XCTAssertEqual(CloudStyle.duration(14 * 60 + 5), "14m 05s")
        XCTAssertEqual(CloudStyle.duration(42), "42s")
        XCTAssertEqual(CloudStyle.duration(-5), "0s")
        XCTAssertEqual(CloudStyle.countdown(to: now.addingTimeInterval(90), now: now), "1m 30s")
        XCTAssertEqual(CloudStyle.countdown(to: now.addingTimeInterval(-1), now: now), "expired")
    }

    func testBudgetBarTurnsAmberAtEightyPercentAndRedAtTheCap() {
        XCTAssertEqual(CloudStyle.level(fraction: 0.79), .ok)
        XCTAssertEqual(CloudStyle.level(fraction: 0.8), .warning)
        XCTAssertEqual(CloudStyle.level(fraction: 0.999), .warning)
        XCTAssertEqual(CloudStyle.level(fraction: 1), .exhausted)
        XCTAssertEqual(CloudStyle.level(fraction: 1.4), .exhausted)
    }

    func testBudgetFractionExtrapolatesFromTheBaseline() throws {
        let cloud = CloudFixtures.healthy   // $3.10 of $4.30 at $1.56/h
        XCTAssertEqual(try XCTUnwrap(CloudStyle.budgetFraction(cloud, now: now)), 3.1 / 4.3, accuracy: 1e-9)
        XCTAssertEqual(CloudStyle.budgetLevel(cloud, now: now), .ok)
        // 20 minutes on: 3.10 + 0.52 = 3.62 -> 84%.
        let later = now.addingTimeInterval(20 * 60)
        XCTAssertEqual(cloud.spent(at: later), 3.62, accuracy: 1e-9)
        XCTAssertEqual(CloudStyle.budgetLevel(cloud, now: later), .warning)
        XCTAssertNil(CloudStyle.budgetFraction(CloudFixtures.unbudgeted, now: now))
        XCTAssertNil(CloudStyle.budgetLevel(CloudFixtures.unbudgeted, now: now))
    }

    func testAnExhaustionDateInThePastIsExhaustedWhateverTheSpendSays() {
        var cloud = CloudFixtures.healthy
        cloud.budgetExhaustsAt = now.addingTimeInterval(-1)
        XCTAssertEqual(CloudStyle.budgetLevel(cloud, now: now), .exhausted)
        XCTAssertEqual(CloudStyle.runsOut(cloud, now: now), "budget used up")
        XCTAssertEqual(CloudStyle.budgetLevel(CloudFixtures.failed, now: now), .exhausted)
    }

    func testRunsOutNamesTheTimeLeftAndIsAbsentWithoutABudgetOrAnExhaustionDate() {
        XCTAssertEqual(CloudStyle.runsOut(CloudFixtures.healthy, now: now), "runs out in 45m 00s")
        XCTAssertNil(CloudStyle.runsOut(CloudFixtures.unbudgeted, now: now))
        var cloud = CloudFixtures.healthy
        cloud.budgetExhaustsAt = nil   // every machine's deadline comes first
        XCTAssertNil(CloudStyle.runsOut(cloud, now: now))
    }

    func testMonthFraction() {
        XCTAssertEqual(CloudStyle.monthFraction(CloudFixtures.healthy) ?? 0, 0.2075, accuracy: 1e-9)
        XCTAssertNil(CloudStyle.monthFraction(CloudFixtures.failed))
    }

    func testExtendIsAllowedOnlyWhileAnotherHourFitsUnderTheMachinesOwnTimer() {
        // Deadline in 5.5h, own timer in 9h: fits.
        XCTAssertTrue(CloudStyle.canExtend(CloudFixtures.machine("a", left: 5.5 * 3600, own: 9 * 3600)))
        // Exactly one hour of room: still fits.
        XCTAssertTrue(CloudStyle.canExtend(CloudFixtures.machine("a", left: 3600, own: 7200)))
        // 59m59s of room: refused.
        XCTAssertFalse(CloudStyle.canExtend(CloudFixtures.machine("a", left: 3600, own: 7199)))
        // No machine TTL: the deadline is the limit, so never.
        XCTAssertFalse(CloudStyle.canExtend(CloudFixtures.machine("a", left: 3600, own: nil)))
    }

    func testTheFootnoteExplainsADisabledExtendAndIsAbsentOtherwise() {
        let stuck = CloudFixtures.machine("a", left: 3600, own: 3600 + 600)
        XCTAssertEqual(CloudStyle.extendFootnote(stuck, now: now),
                       "Can't extend: this machine's own timer ends in 1h 10m, less than an hour past its deadline.")
        XCTAssertNil(CloudStyle.extendFootnote(CloudFixtures.machine("a", own: 20 * 3600), now: now))
    }

    func testMachineDetailSkipsWhatAUserModuleDoesNotName() {
        XCTAssertEqual(CloudStyle.detail(CloudFixtures.machine("a")), "aws · g5.xlarge · us-east-1 · tailnet")
        XCTAssertEqual(CloudStyle.detail(CloudFixtures.machine("a", type: "")), "aws · us-east-1 · tailnet")
        XCTAssertEqual(CloudStyle.stateLabel(CloudFixtures.machine("a", state: "provisioning")), "Provisioning")
        XCTAssertTrue(CloudStyle.isFailed(CloudFixtures.machine("a", state: "failed")))
        XCTAssertFalse(CloudStyle.isFailed(CloudFixtures.machine("a")))
    }

    func testTheIconTurnsToAWarningOnlyForAFailure() {
        XCTAssertEqual(CloudStyle.iconName(CloudFixtures.healthy), "cloud.fill")
        XCTAssertEqual(CloudStyle.iconName(CloudFixtures.failed), "exclamationmark.icloud.fill")
        XCTAssertEqual(CloudStyle.iconLabel(CloudFixtures.healthy), "2 cloud machines")
        XCTAssertEqual(CloudStyle.iconLabel(CloudFixtures.failed), "1 cloud machine, needs attention")
    }

    func testFailureTextSaysToUpdateAnOlderMacAndOtherwiseRelaysTheMacsSentence() {
        let update = "Update Flight Deck on your Mac to control cloud machines from the phone."
        XCTAssertEqual(CloudStyle.failureText(.server(code: "out_of_scope", message: nil)), update)
        XCTAssertEqual(CloudStyle.failureText(.server(code: "unsupported", message: nil)), update)
        XCTAssertEqual(CloudStyle.failureText(.server(code: "infra_refused", message: "extend past the cap")), "extend past the cap")
        XCTAssertEqual(CloudStyle.failureText(.server(code: "infra_failed", message: nil)), "Your Mac refused (infra_failed).")
        XCTAssertTrue(CloudStyle.failureText(.disconnected).hasPrefix("Lost the connection"))
    }
}
