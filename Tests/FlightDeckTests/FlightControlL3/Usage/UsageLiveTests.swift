import XCTest
import IntakeKit
@testable import FlightDeck

/// The meters against the real binaries, because both vendors' payloads are claims that expire
/// (see the "codex behaviour claims expire" note). Skipped unless `USAGE_LIVE=1` (or
/// `TEST_RUNNER_USAGE_LIVE=1`). The codex test spends no tokens; the claude test runs one tiny
/// headless turn on the built-in account.
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

    /// Only meaningful because probe 2 found that headless `claude -p` fires `session.measure`
    /// (Outcome 4C). The usage mod is part of the one bundled `ClaudePlugin`.
    func testTheBundledModWritesAUsageFileForARealTurn() throws {
        guard live else { throw XCTSkip("set USAGE_LIVE=1") }
        let bundled = try XCTUnwrap(ClaudePluginLocation.directory(bundle: Bundle(for: Self.self)))
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fd-usage-live-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // The engine writes type declarations into any --plugin-dir at load; run a copy so it
        // never writes into the test bundle.
        let plugin = try ClaudePluginLocation.materialize(from: bundled, to: dir.appendingPathComponent("plugin"))
        let tab = UUID()

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["claude", "-p", "Reply with the single word ok.", "--plugin-dir", plugin.path]
        var env = ProcessInfo.processInfo.environment
        // Probing claude from inside claude: without this the child runs as a nested session.
        env.removeValue(forKey: "CLAUDE_CODE_CHILD_SESSION"); env.removeValue(forKey: "CLAUDECODE")
        env["FLIGHT_DECK_USAGE_DIR"] = dir.path
        env["FLIGHT_DECK_SESSION_ID"] = tab.uuidString
        p.environment = env
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { throw XCTSkip("claude is not runnable here: \(error)") }
        p.waitUntilExit()

        let data = try Data(contentsOf: dir.appendingPathComponent("\(tab.uuidString).json"))
        let file = try XCTUnwrap(ModUsageFile.decode(data))
        XCTAssertEqual(file.tab, tab.uuidString)
        XCTAssertFalse(file.windows.isEmpty, "a subscription login reports five_hour and seven_day")
        for w in file.windows { XCTAssertTrue((0...1.5).contains(w.utilization), "\(w.name) = \(w.utilization)") }
    }
}
