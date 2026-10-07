import XCTest
@testable import HostKit

final class CostModelTests: XCTestCase {
    var s = BudgetSettings.default

    func testWorstCaseIsRateTimesTTL() {
        XCTAssertEqual(CostModel.worstCase(hourly: 0.8, ttl: Duration(seconds: 4 * 3600)), 3.2, accuracy: 1e-9)
    }

    func testAllowsWithinEveryLimit() {
        XCTAssertEqual(CostModel.checkLaunch(hourly: 0.8, ttl: .init(seconds: 4*3600), idle: .init(seconds: 1800),
            instanceType: "g6.xlarge", cloud: "aws", running: 0, monthToDate: 10, settings: s), .allowed)
    }

    func testPerMachineCapBoundary() {
        // $10 cap: 12.5h at $0.80 = $10.00 exactly is allowed; one more minute is not.
        var longTTL = s
        longTTL.maxTTL = .init(seconds: 86_400)
        XCTAssertEqual(CostModel.checkLaunch(hourly: 0.8, ttl: .init(seconds: 45_000), idle: .init(seconds: 60),
            instanceType: "g6.xlarge", cloud: "aws", running: 0, monthToDate: 0, settings: longTTL), .allowed)
        guard case .refused(let why) = CostModel.checkLaunch(hourly: 0.8, ttl: .init(seconds: 45_060), idle: .init(seconds: 60),
            instanceType: "g6.xlarge", cloud: "aws", running: 0, monthToDate: 0, settings: longTTL)
        else { return XCTFail() }
        XCTAssertTrue(why.contains("per-machine"), why)
    }

    func testMonthlyCapCountsMonthToDate() {
        guard case .refused(let why) = CostModel.checkLaunch(hourly: 1, ttl: .init(seconds: 3*3600), idle: .init(seconds: 60),
            instanceType: "g6.xlarge", cloud: "aws", running: 0, monthToDate: 48, settings: s) else { return XCTFail() }
        XCTAssertTrue(why.contains("monthly") && why.contains("48"), why)
    }

    func testUnpricedRefusedOnlyWhenADollarCapIsSet() {
        guard case .refused = CostModel.checkLaunch(hourly: nil, ttl: .init(seconds: 3600), idle: .init(seconds: 60),
            instanceType: "t3.small", cloud: "aws", running: 0, monthToDate: 0, settings: s) else { return XCTFail() }
        var noCaps = s; noCaps.monthlyCapUSD = nil; noCaps.perMachineCapUSD = nil
        XCTAssertEqual(CostModel.checkLaunch(hourly: nil, ttl: .init(seconds: 3600), idle: .init(seconds: 60),
            instanceType: "t3.small", cloud: "aws", running: 0, monthToDate: 0, settings: noCaps), .allowed)
    }

    func testGuardrails() {
        let s = self.s
        func refused(_ t: String, cloud: String = "aws", running: Int = 0, ttl: Int = 3600, idle: Int = 60) -> Bool {
            if case .refused = CostModel.checkLaunch(hourly: 0.1, ttl: .init(seconds: ttl), idle: .init(seconds: idle),
                instanceType: t, cloud: cloud, running: running, monthToDate: 0, settings: s) { return true }
            return false
        }
        XCTAssertTrue(refused("p5.48xlarge"))
        XCTAssertFalse(refused("t3.small"))
        XCTAssertTrue(refused("t3.small", running: 2))
        XCTAssertTrue(refused("t3.small", ttl: 13 * 3600))
        XCTAssertTrue(refused("t3.small", idle: 3 * 3600))
        XCTAssertFalse(refused("e2-standard-2", cloud: "gcp"))
        XCTAssertTrue(refused("a3-highgpu-8g", cloud: "gcp"))
    }

    func testRunningThresholds() {
        XCTAssertEqual(CostModel.checkRunning(spent: 5, monthToDate: 20, settings: s), .ok)
        guard case .warn = CostModel.checkRunning(spent: 8.1, monthToDate: 20, settings: s) else { return XCTFail() }
        guard case .destroy = CostModel.checkRunning(spent: 10, monthToDate: 20, settings: s) else { return XCTFail() }
        guard case .destroy = CostModel.checkRunning(spent: 1, monthToDate: 50, settings: s) else { return XCTFail() }
    }

    func testGlob() {
        XCTAssertTrue(CostModel.globMatches("t3.*", "t3.micro"))
        XCTAssertTrue(CostModel.globMatches("m6i.*large", "m6i.xlarge"))
        XCTAssertFalse(CostModel.globMatches("m6i.*large", "m6i.metal"))
        XCTAssertFalse(CostModel.globMatches("t3.*", "t3a.micro"))
    }
}
