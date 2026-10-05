import XCTest
import IntakeKit
@testable import FlightDeck

/// Three sources with three failure shapes: a directory another process writes into (torn
/// writes, stale files, foreign names), seat activity that repeats the same numbers on every
/// tick, and an error stream with no meter at all. These pin that each yields a reading once
/// per real change and never a half-read one.
@MainActor
final class UsageSourcesTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("fd-usage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func write(_ name: String, _ data: Data, mtime: Date) throws {
        let url = dir.appendingPathComponent(name)
        try data.write(to: url)
        try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: url.path)
    }

    func testScanYieldsEachFileOncePerChange() throws {
        let tab = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let fixture = try UsageFixtures.data("claude-mod-usage")
        try write("\(tab.uuidString).json", fixture, mtime: Date(timeIntervalSince1970: 1_000))
        let source = ClaudeModUsageSource(directory: dir)
        let first = source.scan()
        XCTAssertEqual(first.map(\.stem), [tab])
        XCTAssertEqual(first.first?.file.windows.first?.name, "five_hour")
        XCTAssertTrue(source.scan().isEmpty, "unchanged since the last scan")
        try write("\(tab.uuidString).json", fixture, mtime: Date(timeIntervalSince1970: 1_001))
        XCTAssertEqual(source.scan().count, 1)
    }

    func testATornWriteIsRetriedNotSkipped() throws {
        let tab = UUID()
        try write("\(tab.uuidString).json", Data(#"{"v":1,"readAt":"2026-10-04T19:00:00.000Z","rateLim"#.utf8), mtime: Date(timeIntervalSince1970: 1_000))
        let source = ClaudeModUsageSource(directory: dir)
        XCTAssertTrue(source.scan().isEmpty)
        try write("\(tab.uuidString).json", try UsageFixtures.data("claude-mod-usage"), mtime: Date(timeIntervalSince1970: 1_000))
        XCTAssertEqual(source.scan().count, 1, "same mtime, but the torn read was never recorded as seen")
    }

    func testAClaudeSessionIDNamedFileScansAndForeignNamesDoNot() throws {
        try write("8552adc8-bbae-48c2-9b86-29a5becfa369.json", try UsageFixtures.data("claude-mod-usage"), mtime: Date())
        try write("notes.json", Data("{}".utf8), mtime: Date())
        try write("\(UUID().uuidString).tmp", Data("{}".utf8), mtime: Date())
        XCTAssertEqual(ClaudeModUsageSource(directory: dir).scan().map(\.stem), [UUID(uuidString: "8552ADC8-BBAE-48C2-9B86-29A5BECFA369")!])
    }

    func testAMissingDirectoryIsEmptyNotAnError() {
        XCTAssertTrue(ClaudeModUsageSource(directory: dir.appendingPathComponent("nope")).scan().isEmpty)
    }

    func testPruneRemovesOnlyOldFiles() throws {
        let now = Date(timeIntervalSince1970: 10_000_000)
        try write("old.json", Data("{}".utf8), mtime: now.addingTimeInterval(-8 * 86_400))
        try write("new.json", Data("{}".utf8), mtime: now.addingTimeInterval(-60))
        ClaudeModUsageSource(directory: dir).prune(olderThan: 7 * 86_400, now: now)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), ["new.json"])
    }

    private func seat(windows: [UsageWindow]?, status: String?, resets: Date? = nil, last: Date, harness: Harness = .claude) -> SeatActivity {
        var a = SeatActivity(harness: harness, startedAt: Date(timeIntervalSince1970: 0))
        a.rateLimitWindows = windows; a.rateLimitStatus = status; a.rateLimitResetsAt = resets; a.lastEventAt = last
        // A rejecting event sets rateLimitedAt in the real fold; the next assistant event clears it.
        if let status, !status.hasPrefix("allowed") { a.rateLimitedAt = last }
        return a
    }

    func testHeadlessSeatsYieldAReadingPerNewEvent() {
        let source = HeadlessClaudeUsageSource()
        let w = [UsageWindow(name: "five_hour", utilization: 0.4, resetsAt: nil)]
        let a = seat(windows: w, status: "allowed", last: Date(timeIntervalSince1970: 100))
        let first = source.readings(from: [a], account: UsageRefs.work)
        XCTAssertEqual(first, [UsageReading(account: UsageRefs.work, windows: w, readAt: Date(timeIntervalSince1970: 100), source: "claude headless", hardRejection: false)])
        XCTAssertEqual(source.readings(from: [a], account: UsageRefs.work), [], "the same event is not news")
        let b = seat(windows: w, status: "allowed", last: Date(timeIntervalSince1970: 160))
        XCTAssertEqual(source.readings(from: [b], account: UsageRefs.work).count, 1)
    }

    func testARejectedSeatIsAHardRejectionUntilItsReset() {
        let resets = Date(timeIntervalSince1970: 5_000)
        let a = seat(windows: [UsageWindow(name: "five_hour", utilization: 1, resetsAt: resets)], status: "rejected", resets: resets,
                     last: Date(timeIntervalSince1970: 100))
        let r = HeadlessClaudeUsageSource().readings(from: [a], account: UsageRefs.work)
        XCTAssertEqual(r.first?.hardRejection, true)
        XCTAssertEqual(r.first?.worstWindow?.resetsAt, resets)
    }

    func testARecoveredSeatWithAStaleRejectedStatusIsNotARejection() {
        let w = [UsageWindow(name: "five_hour", utilization: 0.3, resetsAt: nil)]
        var a = seat(windows: w, status: "rejected", last: Date(timeIntervalSince1970: 100))
        a.rateLimitedAt = nil // the next assistant event cleared it; the status string stays verbatim
        let r = HeadlessClaudeUsageSource().readings(from: [a], account: UsageRefs.work)
        XCTAssertEqual(r.count, 1)
        XCTAssertEqual(r.first?.hardRejection, false)
        XCTAssertEqual(r.first?.windows, w)
    }

    func testCodexSeatsAndSeatsWithoutRateLimitsAreSkipped() {
        let source = HeadlessClaudeUsageSource()
        XCTAssertEqual(source.readings(from: [seat(windows: [UsageWindow(name: "x", utilization: 0.1, resetsAt: nil)], status: "allowed",
                                                   last: Date(), harness: .codex)], account: UsageRefs.work), [])
        XCTAssertEqual(source.readings(from: [seat(windows: nil, status: nil, last: Date())], account: UsageRefs.work), [])
    }

    func testOpenCodeSourceStreamsOnlyQuotaRefusals() async {
        let source = OpenCodeErrorUsageSource()
        let at = Date(timeIntervalSince1970: 1_000)
        XCTAssertNil(source.ingest(OpenCodeAPIErrorEvent(status: 500, retryAfter: nil, message: "", at: at), account: UsageRefs.work))
        XCTAssertNotNil(source.ingest(OpenCodeAPIErrorEvent(status: 429, retryAfter: 30, message: "", at: at), account: UsageRefs.work))
        source.finish()
        var got: [UsageReading] = []
        for await r in source.readings { got.append(r) }
        XCTAssertEqual(got.map(\.hardRejection), [true])
        XCTAssertEqual(got.first?.worstWindow?.resetsAt, at.addingTimeInterval(30))
    }
}
