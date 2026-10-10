import XCTest
import IntakeKit

/// Headless `claude -p` seats are the only claude processes Flight Deck parses a stream for, and
/// every API call there carries a `rate_limit_event` with the account's real windows. Until now
/// the fold kept only the `status`; these pin that it keeps the windows too, so intake seats
/// meter the account they run on.
final class SeatActivityRateWindowTests: XCTestCase {
    private func load(_ name: String) throws -> Data {
        try Data(contentsOf: try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "jsonl", subdirectory: "Fixtures/Intake")))
    }

    func testKeepsUnifiedWindowsFromTheLiveSample() throws {
        var p = ActivityParser(agent: .claude, project: URL(fileURLWithPath: "/p"), now: { Date(timeIntervalSince1970: 0) })
        p.feed(try load("claude-stream-activity"))
        XCTAssertEqual(p.activity.rateLimitWindows, [
            UsageWindow(name: "five_hour", utilization: 0.01, resetsAt: Date(timeIntervalSince1970: 1790567400)),
            UsageWindow(name: "seven_day", utilization: 0.43, resetsAt: Date(timeIntervalSince1970: 1791032400)),
        ])
        XCTAssertEqual(p.activity.rateLimitStatus, "allowed")
        XCTAssertEqual(p.activity.rateLimitResetsAt, Date(timeIntervalSince1970: 1790567400))
        XCTAssertNil(p.activity.rateLimitedAt, "allowed is still not a limit")
    }

    func testARejectedEventRecordsStatusAndStillSetsRateLimitedAt() {
        let clock = Date(timeIntervalSince1970: 1_790_000_000)
        var p = ActivityParser(agent: .claude, project: URL(fileURLWithPath: "/p"), now: { clock })
        let line = #"{"type":"rate_limit_event","rate_limit_info":{"status":"rejected","resetsAt":1790567400,"unifiedWindows":{"five_hour":{"utilization":1.0,"resetsAt":1790567400}}}}"# + "\n"
        p.feed(Data(line.utf8))
        XCTAssertEqual(p.activity.rateLimitStatus, "rejected")
        XCTAssertEqual(p.activity.rateLimitedAt, clock)
        XCTAssertEqual(p.activity.rateLimitWindows?.first?.utilization, 1.0)
    }

    func testAnEventWithoutWindowsKeepsTheLastWindows() {
        var p = ActivityParser(agent: .claude, project: URL(fileURLWithPath: "/p"), now: { Date() })
        p.feed(Data((#"{"type":"rate_limit_event","rate_limit_info":{"status":"allowed","unifiedWindows":{"five_hour":{"utilization":0.5,"resetsAt":1790567400}}}}"# + "\n").utf8))
        p.feed(Data((#"{"type":"rate_limit_event","rate_limit_info":{"status":"allowed"}}"# + "\n").utf8))
        XCTAssertEqual(p.activity.rateLimitWindows?.first?.utilization, 0.5)
    }

    /// `activity.json` files written before this change have none of the new keys; they must
    /// still decode, or every live round's seat rows go blank after an upgrade.
    func testOldActivityJSONStillDecodes() throws {
        var a = SeatActivity(agent: .claude, startedAt: Date(timeIntervalSince1970: 0))
        a.rateLimitWindows = [UsageWindow(name: "five_hour", utilization: 0.5, resetsAt: nil)]
        a.rateLimitStatus = "allowed"
        var obj = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(a)) as? [String: Any])
        obj.removeValue(forKey: "rateLimitWindows"); obj.removeValue(forKey: "rateLimitStatus"); obj.removeValue(forKey: "rateLimitResetsAt")
        let old = try JSONDecoder().decode(SeatActivity.self, from: JSONSerialization.data(withJSONObject: obj))
        XCTAssertNil(old.rateLimitWindows)
        XCTAssertNil(old.rateLimitStatus)
    }
}
