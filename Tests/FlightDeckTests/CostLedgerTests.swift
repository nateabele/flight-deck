import XCTest
@testable import FlightDeck

@MainActor
final class CostLedgerTests: XCTestCase {
    var url: URL!
    var cal: Calendar = { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }()
    override func setUp() { url = FileManager.default.temporaryDirectory.appendingPathComponent("ledger-\(UUID()).json") }
    func d(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }

    func testSpentIsRateTimesElapsed() throws {
        let l = CostLedger(fileURL: url, calendar: cal)
        try l.open(name: "gpu", hourlyUSD: 0.8, at: d("2026-10-10T10:00:00Z"))
        XCTAssertEqual(l.spent(name: "gpu", now: d("2026-10-10T11:30:00Z")), 1.2, accuracy: 1e-9)
        try l.close(name: "gpu", at: d("2026-10-10T12:00:00Z"))
        XCTAssertEqual(l.spent(name: "gpu", now: d("2026-10-10T20:00:00Z")), 1.6, accuracy: 1e-9)
    }

    /// Review Focus 4.
    func testSegmentSplitsAcrossMonths() throws {
        let l = CostLedger(fileURL: url, calendar: cal)
        try l.open(name: "gpu", hourlyUSD: 1, at: d("2026-10-31T22:00:00Z"))
        XCTAssertEqual(l.monthToDate(now: d("2026-11-01T03:00:00Z")), 3, accuracy: 1e-9, "only November's 3 hours")
        XCTAssertEqual(l.monthToDate(now: d("2026-10-31T23:00:00Z")), 1, accuracy: 1e-9)
    }

    func testPersistsAcrossInstances() throws {
        try CostLedger(fileURL: url, calendar: cal).open(name: "a", hourlyUSD: 2, at: d("2026-10-10T00:00:00Z"))
        XCTAssertEqual(CostLedger(fileURL: url, calendar: cal).spent(name: "a", now: d("2026-10-10T01:00:00Z")), 2, accuracy: 1e-9)
    }

    /// A rate change must not reprice the hours already spent at the old rate.
    func testOpenClosesTheOpenSegmentFirst() throws {
        let l = CostLedger(fileURL: url, calendar: cal)
        try l.open(name: "a", hourlyUSD: 1, at: d("2026-10-10T00:00:00Z"))
        try l.open(name: "a", hourlyUSD: 3, at: d("2026-10-10T02:00:00Z"))
        XCTAssertEqual(l.spent(name: "a", now: d("2026-10-10T03:00:00Z")), 5, accuracy: 1e-9)
    }
}
