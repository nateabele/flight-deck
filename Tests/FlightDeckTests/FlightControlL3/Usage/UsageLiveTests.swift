import XCTest
import IntakeKit
@testable import FlightDeck

/// The meters against the real binaries, because both vendors' payloads are claims that expire
/// (see the "codex behaviour claims expire" note). Skipped unless `USAGE_LIVE=1` (or
/// `TEST_RUNNER_USAGE_LIVE=1`). The codex test spends no tokens.
@MainActor
final class UsageLiveTests: XCTestCase {
    private var live: Bool {
        let e = ProcessInfo.processInfo.environment
        return e["USAGE_LIVE"] == "1" || e["TEST_RUNNER_USAGE_LIVE"] == "1"
    }

    func testCodexAppServerReadsTheRealAccountsRateLimits() async throws {
        guard live else { throw XCTSkip("set USAGE_LIVE=1") }
        let transport = CodexProcessTransport(home: AgentID.codex.builtInHome)
        let rpc = CodexRPC(transport: transport)
        transport.onTerminate = { [weak rpc] in rpc?.transportClosed() }
        do { try transport.start() } catch { throw XCTSkip("codex app-server did not start: \(error)") }
        defer { transport.stop() }
        try await CodexProcessTransport.verifyHandshake(rpc, timeoutSeconds: 15)
        let result = try await rpc.request("account/rateLimits/read", [:])
        let buckets = CodexRateLimitParser.readResponse(result)
        XCTAssertFalse(buckets.isEmpty, "a ChatGPT login reports at least one bucket; got \(result)")
        let reading = try XCTUnwrap(CodexRateLimitParser.reading(buckets, account: AccountRef(harness: "codex", id: UUID(), label: "live"), readAt: Date()))
        XCTAssertFalse(reading.windows.isEmpty)
        for w in reading.windows { XCTAssertTrue((0...1.5).contains(w.utilization), "\(w.name) = \(w.utilization)") }
    }

    // No live claude test here: headless `claude -p` runs no status line, and an interactive
    // claude cannot be driven from this runner. The status line's live check is a tmux probe;
    // see the L3-U spec §12.
}
