import XCTest
import IntakeKit

/// Every meter is a different vendor's shape for the same three facts — how full a window is,
/// when it resets, and whether the account was refused. These pin each translation against the
/// recorded or schema-shaped payloads, so a vendor rename shows up here, not as an account that
/// silently reads "no reading" forever.
final class UsageParsersTests: XCTestCase {
    func testRateLimitClassifierNamesOnlyQuotaFailures() {
        XCTAssertTrue(RateLimitClassifier.isRateLimit(status: 429, kind: nil))
        XCTAssertTrue(RateLimitClassifier.isRateLimit(status: nil, kind: "rate_limit"))
        XCTAssertTrue(RateLimitClassifier.isRateLimit(status: nil, kind: "rate_limit_exceeded"))
        XCTAssertTrue(RateLimitClassifier.isRateLimit(status: nil, kind: "usage_limit_exceeded"))
        XCTAssertFalse(RateLimitClassifier.isRateLimit(status: 529, kind: "overloaded"),
                       "an overloaded API is everyone's problem, not this account's quota")
        XCTAssertFalse(RateLimitClassifier.isRateLimit(status: nil, kind: "server_overloaded"))
        XCTAssertFalse(RateLimitClassifier.isRateLimit(status: nil, kind: nil))
    }

    func testWindowNamesFollowTheirDuration() {
        XCTAssertEqual(UsageWindowName.forDuration(minutes: 300), "five_hour")
        XCTAssertEqual(UsageWindowName.forDuration(minutes: 10080), "seven_day")
        XCTAssertEqual(UsageWindowName.forDuration(minutes: 60), "60m")
        XCTAssertEqual(UsageWindowName.forDuration(minutes: nil), "window")
    }

    func testCodexReadPrefersTheMultiBucketView() throws {
        let buckets = CodexRateLimitParser.readResponse(try UsageFixtures.object("codex-rate-limits-read"))
        XCTAssertEqual(Set(buckets.keys), ["codex", "codex_bengalfox"])
        XCTAssertEqual(buckets["codex"]?.primary, UsageWindow(name: "five_hour", utilization: 0.42, resetsAt: usageISO("2026-10-04T23:00:00Z")))
        XCTAssertEqual(buckets["codex"]?.secondary, UsageWindow(name: "seven_day", utilization: 0.71, resetsAt: usageISO("2026-10-09T00:00:00Z")))
        XCTAssertEqual(buckets["codex_bengalfox"]?.primary?.name, "codex_bengalfox:five_hour",
                       "a second bucket's windows say which bucket they are")
        XCTAssertNil(buckets["codex_bengalfox"]?.secondary)
    }

    func testCodexReadFallsBackToTheSingleBucketView() throws {
        var result = try UsageFixtures.object("codex-rate-limits-read")
        result["rateLimitsByLimitId"] = NSNull()
        let buckets = CodexRateLimitParser.readResponse(result)
        XCTAssertEqual(Array(buckets.keys), ["codex"])
        XCTAssertEqual(buckets["codex"]?.primary?.utilization ?? 0, 0.42, accuracy: 1e-9)
    }

    func testCodexReadingIsWorstAcrossBuckets() throws {
        let buckets = CodexRateLimitParser.readResponse(try UsageFixtures.object("codex-rate-limits-read"))
        let at = usageISO("2026-10-04T18:00:00Z")
        let r = try XCTUnwrap(CodexRateLimitParser.reading(buckets, account: AccountRef(harness: "codex", id: UUID(), label: "C"), readAt: at))
        XCTAssertEqual(r.worstWindow?.name, "codex_bengalfox:five_hour")
        XCTAssertEqual(r.worstWindow?.utilization ?? 0, 0.88, accuracy: 1e-9)
        XCTAssertFalse(r.hardRejection)
        XCTAssertEqual(r.source, "codex app-server")
        XCTAssertNil(CodexRateLimitParser.reading([:], account: r.account, readAt: at), "no buckets is no reading, not an empty one")
    }

    func testCodexUpdateIsSparseAndMergesIntoTheLastRead() throws {
        let read = CodexRateLimitParser.readResponse(try UsageFixtures.object("codex-rate-limits-read"))
        let merged = CodexRateLimitParser.merge(update: try UsageFixtures.object("codex-rate-limits-updated"), into: read)
        XCTAssertEqual(merged["codex"]?.primary?.utilization ?? 0, 0.96, accuracy: 1e-9)
        XCTAssertEqual(merged["codex"]?.secondary?.utilization ?? 0, 0.71, accuracy: 1e-9,
                       "a null window in a rolling update is 'not sent', not 'empty'")
        XCTAssertEqual(merged["codex_bengalfox"], read["codex_bengalfox"])
    }

    func testCodexReachedLimitIsAHardRejection() {
        let snap: [String: Any] = ["limitId": "codex", "primary": ["usedPercent": 100, "windowDurationMins": 300, "resetsAt": 1791154800],
                                   "rateLimitReachedType": "rate_limit_reached"]
        let buckets = CodexRateLimitParser.readResponse(["rateLimits": snap])
        let r = CodexRateLimitParser.reading(buckets, account: AccountRef(harness: "codex", id: UUID(), label: "C"), readAt: Date())
        XCTAssertEqual(r?.hardRejection, true)
        XCTAssertEqual(r?.worstWindow?.resetsAt, usageISO("2026-10-04T23:00:00Z"))
    }

    func testClaudeUnifiedWindowsFromAStreamRecord() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "claude-stream-activity", withExtension: "jsonl", subdirectory: "Fixtures/Intake"))
        let line = try XCTUnwrap(String(contentsOf: url, encoding: .utf8).split(separator: "\n").first { $0.contains("\"rate_limit_event\"") })
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        let info = try XCTUnwrap(obj["rate_limit_info"] as? [String: Any])
        XCTAssertEqual(ClaudeRateLimitParser.windows(rateLimitInfo: info), [
            UsageWindow(name: "five_hour", utilization: 0.01, resetsAt: Date(timeIntervalSince1970: 1790567400)),
            UsageWindow(name: "seven_day", utilization: 0.43, resetsAt: Date(timeIntervalSince1970: 1791032400)),
        ])
        XCTAssertFalse(ClaudeRateLimitParser.isRejected(rateLimitInfo: info))
        XCTAssertEqual(ClaudeRateLimitParser.resetsAt(rateLimitInfo: info), Date(timeIntervalSince1970: 1790567400))
    }

    func testClaudeStatusOtherThanAllowedIsARejection() {
        XCTAssertTrue(ClaudeRateLimitParser.isRejected(rateLimitInfo: ["status": "rejected"]))
        XCTAssertFalse(ClaudeRateLimitParser.isRejected(rateLimitInfo: ["status": "allowed_warning"]))
        XCTAssertFalse(ClaudeRateLimitParser.isRejected(rateLimitInfo: [:]), "no status is no evidence")
    }

    func testModFileDecodesWithAndWithoutFractionalSeconds() throws {
        let file = try XCTUnwrap(ClaudeUsageFile.decode(try UsageFixtures.data("claude-usage-file")))
        XCTAssertEqual(file.tab, "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")
        XCTAssertEqual(file.readAt, usageISO("2026-10-04T19:00:00.000Z"))
        XCTAssertEqual(file.windows.map(\.name), ["five_hour", "seven_day"])
        XCTAssertEqual(file.windows[0].utilization, 82.5 / 100, accuracy: 1e-9)
        XCTAssertEqual(file.windows[1].resetsAt, usageISO("2026-10-09T00:00:00Z"))
    }

    func testModFileRejectsATornWriteAndANewerVersion() {
        XCTAssertNil(ClaudeUsageFile.decode(Data(#"{"v":1,"tab":"x","readAt":"2026-10-04T19:00:00.000Z","rateLim"#.utf8)))
        XCTAssertNil(ClaudeUsageFile.decode(Data(#"{"v":2,"readAt":"2026-10-04T19:00:00.000Z","rateLimits":[]}"#.utf8)))
        XCTAssertNil(ClaudeUsageFile.decode(Data(#"{"v":1,"readAt":"yesterday","rateLimits":[]}"#.utf8)))
    }

    func testOpenCode429WithRetryAfterEndsThen() throws {
        let at = usageISO("2026-10-04T18:00:00Z")
        let r = try XCTUnwrap(OpenCodeRateLimit.reading(for: OpenCodeAPIErrorEvent(status: 429, retryAfter: 120, message: "slow down", at: at),
                                                        account: UsageRefs.work))
        XCTAssertTrue(r.hardRejection)
        XCTAssertEqual(r.worstWindow?.resetsAt, at.addingTimeInterval(120))
    }

    func testOpenCode429WithoutRetryAfterLeavesTheBackoffToPolicy() throws {
        let r = try XCTUnwrap(OpenCodeRateLimit.reading(for: OpenCodeAPIErrorEvent(status: 429, retryAfter: nil, message: "", at: Date()),
                                                        account: UsageRefs.work))
        XCTAssertTrue(r.hardRejection)
        XCTAssertEqual(r.windows, [], "no reset time: HeadroomPolicy applies its 15-minute backoff")
        XCTAssertEqual(OpenCodeRateLimit.backoff, 15 * 60)
    }

    func testOpenCodeOtherErrorsAreNotMeters() {
        XCTAssertNil(OpenCodeRateLimit.reading(for: OpenCodeAPIErrorEvent(status: 500, retryAfter: nil, message: "", at: Date()),
                                               account: UsageRefs.work))
    }

    /// The real payload from probe 3, not the schema-shaped one: a field codex renamed between
    /// the pinned schema and today fails here.
    func testParsesTheCapturedReadResponse() throws {
        let buckets = CodexRateLimitParser.readResponse(try UsageFixtures.object("codex-rate-limits-read.captured"))
        XCTAssertFalse(buckets.isEmpty)
        let r = try XCTUnwrap(CodexRateLimitParser.reading(buckets, account: UsageRefs.codex, readAt: Date()))
        XCTAssertFalse(r.windows.isEmpty)
        for w in r.windows { XCTAssertTrue((0...1.5).contains(w.utilization), "\(w.name) = \(w.utilization)") }
    }

    /// The real push carries `spendControlReached: null` and extra fields; it must merge, not throw away the bucket.
    func testMergesTheCapturedUpdateIntoTheCapturedRead() throws {
        let read = CodexRateLimitParser.readResponse(try UsageFixtures.object("codex-rate-limits-read.captured"))
        let merged = CodexRateLimitParser.merge(update: try UsageFixtures.object("codex-rate-limits-updated.captured"), into: read)
        XCTAssertEqual(Set(merged.keys), Set(read.keys))
        XCTAssertEqual(merged["codex"]?.primary?.resetsAt, Date(timeIntervalSince1970: 1791200667))
        XCTAssertNil(merged["codex"]?.reachedType)
    }

    /// The file claude's mod really wrote in probe 4: fractional `readAt`, an extra `changed`
    /// field, and a percentage that is not a whole number.
    func testModFileDecodesTheCapturedShape() throws {
        let json = #"{"v":1,"tab":"11111111-2222-3333-4444-555555555555","session":"70505722-0000-0000-0000-000000000000","readAt":"2026-10-05T06:32:21.357Z","changed":["context","cost"],"rateLimits":[{"kind":"five_hour","percentUsed":1,"resetsAt":"2026-10-05T11:30:00.000Z"},{"kind":"seven_day","percentUsed":58,"resetsAt":"2026-10-08T21:00:00.000Z"}]}"#
        let file = try XCTUnwrap(ClaudeUsageFile.decode(Data(json.utf8)))
        XCTAssertEqual(file.readAt.timeIntervalSince1970, usageISO("2026-10-05T06:32:21Z").timeIntervalSince1970 + 0.357, accuracy: 0.001)
        XCTAssertEqual(file.windows.map(\.utilization), [0.01, 0.58])
    }

    func testModFileKeepsAnExceededSpendLimitAboveOne() throws {
        let json = #"{"v":1,"readAt":"2026-10-05T06:32:21.357Z","rateLimits":[{"kind":"five_hour","percentUsed":104.5}]}"#
        let file = try XCTUnwrap(ClaudeUsageFile.decode(Data(json.utf8)))
        XCTAssertEqual(file.windows[0].utilization, 1.045, accuracy: 1e-9)
        XCTAssertNil(file.windows[0].resetsAt)
    }

    func testOpenCodeRateLimitBackoffEqualsHeadroomPolicyRejectionBackoff() {
        XCTAssertEqual(OpenCodeRateLimit.backoff, HeadroomPolicy.rejectionBackoff,
                       "a hardcoded backoff here would drift from the ledger's rejection timeout")
    }
}
