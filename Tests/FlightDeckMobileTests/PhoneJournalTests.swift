import XCTest
@testable import FlightDeckMobile

/// The log fetch reads the app's own journal, not `OSLogStore` — which took 18.7 s on a
/// handset and timed out every fetch. These pin what the Mac gets back.
final class PhoneJournalTests: XCTestCase {
    func testAFetchReturnsWhatWasJustLoggedNewestLastAndFast() throws {
        let marker = UUID().uuidString
        PhoneLog.connection.notice("journal-test first \(marker)")
        PhoneLog.answer.error("journal-test second \(marker)")
        PhoneLog.perf.notice("journal-test third\nwrapped \(marker)", flush: true)

        let start = Date()
        let logs = try PhoneLog.entries(seconds: 60, limit: 500).get()
        XCTAssertLessThan(Date().timeIntervalSince(start), 1, "a fetch must answer well inside the Mac's 10 s")
        let mine = logs.entries.filter { $0.message.contains(marker) }
        XCTAssertEqual(mine.map(\.category), ["connection", "answer", "perf"])
        XCTAssertEqual(mine.map(\.level), ["notice", "error", "notice"])
        XCTAssertEqual(mine.last?.message, "journal-test third wrapped \(marker)", "one line per entry")
    }

    func testTheLimitKeepsTheNewestAndSaysItCut() throws {
        let marker = UUID().uuidString
        for index in 0..<5 { PhoneLog.connection.notice("journal-limit \(index) \(marker)") }
        PhoneLog.perf.notice("journal-limit flush \(marker)", flush: true)
        let logs = try PhoneLog.entries(seconds: 60, limit: 2).get()
        XCTAssertEqual(logs.entries.count, 2)
        XCTAssertTrue(logs.truncated)
        XCTAssertEqual(logs.entries.last?.message, "journal-limit flush \(marker)")
    }
}
