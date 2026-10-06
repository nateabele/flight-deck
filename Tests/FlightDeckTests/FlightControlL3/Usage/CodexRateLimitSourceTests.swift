import XCTest
import IntakeKit
@testable import FlightDeck

/// codex reports rate limits two ways: a read Flight Deck asks for, and pushes it is sent only
/// for turns its own connection runs. These pin that pushes now reach a listener instead of
/// being dropped, that a server *request* is not mistaken for one, and that the per-account
/// source turns either into one reading.
@MainActor
final class CodexRateLimitSourceTests: XCTestCase {
    private final class SilentTransport: CodexTransport {
        var onLine: ((String) -> Void)?
        func send(_ line: String) {}
    }

    func testNotificationsReachTheHook() {
        let transport = SilentTransport()
        let rpc = CodexRPC(transport: transport)
        var got: [(String, [String: Any])] = []
        rpc.onNotification = { got.append(($0, $1)) }
        transport.onLine?(#"{"jsonrpc":"2.0","method":"account/rateLimits/updated","params":{"rateLimits":{"limitId":"codex"}}}"#)
        XCTAssertEqual(got.map(\.0), ["account/rateLimits/updated"])
        XCTAssertEqual((got.first?.1["rateLimits"] as? [String: Any])?["limitId"] as? String, "codex")
    }

    func testServerRequestsAndStrayRepliesAreNotNotifications() {
        let transport = SilentTransport()
        let rpc = CodexRPC(transport: transport)
        var got: [String] = []
        rpc.onNotification = { method, _ in got.append(method) }
        transport.onLine?(#"{"jsonrpc":"2.0","id":7,"method":"item/commandExecution/requestApproval","params":{}}"#)
        transport.onLine?(#"{"jsonrpc":"2.0","id":99,"result":{}}"#)
        transport.onLine?("codex banner, not JSON")
        XCTAssertEqual(got, [])
    }

    func testNoAppServerMeansNoReadAndNoSpawn() async throws {
        let store = SessionStore(provider: nil, persistence: nil)
        let result = try await store.codexRateLimitsRead(account: nil)
        XCTAssertNil(result)
        XCTAssertFalse(store.hasCodexStackForTesting, "asking for a meter must never start codex")
    }

    func testReadThenSparseUpdateMakeOneReading() throws {
        let source = CodexRateLimitSource()
        let at = usageISO("2026-10-04T18:00:00Z")
        XCTAssertNil(source.reading(account: UsageRefs.codex, at: at), "nothing read yet")
        source.applyRead(try UsageFixtures.object("codex-rate-limits-read"))
        XCTAssertEqual(source.reading(account: UsageRefs.codex, at: at)?.worstWindow?.utilization ?? 0, 0.88, accuracy: 1e-9)
        source.applyUpdate(try UsageFixtures.object("codex-rate-limits-updated"))
        let r = try XCTUnwrap(source.reading(account: UsageRefs.codex, at: at))
        XCTAssertEqual(r.worstWindow?.utilization ?? 0, 0.96, accuracy: 1e-9)
        XCTAssertEqual(r.account, UsageRefs.codex)
        XCTAssertEqual(r.readAt, at)
    }

    func testAnEmptyReadKeepsTheLastBuckets() throws {
        let source = CodexRateLimitSource()
        source.applyRead(try UsageFixtures.object("codex-rate-limits-read"))
        source.applyRead([:])
        XCTAssertEqual(source.buckets.count, 2, "an empty answer is not evidence the limits vanished")
    }
}
