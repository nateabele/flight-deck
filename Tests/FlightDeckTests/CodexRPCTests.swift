import XCTest
@testable import FlightDeck

@MainActor
final class CodexRPCTests: XCTestCase {
    /// In-memory transport: no subprocess, no pipes, no timing.
    final class StubTransport: CodexTransport {
        var sent: [String] = []
        var onLine: ((String) -> Void)?
        func send(_ line: String) { sent.append(line) }
        func reply(_ json: String) { onLine?(json) }
    }

    func testARequestSerialisesAsOneJSONLine() async throws {
        let t = StubTransport()
        let rpc = CodexRPC(transport: t)

        Task { try? await rpc.request("thread/start", ["cwd": "/w/a"]) }
        try await Task.sleep(nanoseconds: 50_000_000)

        let line = try XCTUnwrap(t.sent.first)
        XCTAssertFalse(line.dropLast().contains("\n"), "the frame is exactly one line")
        let obj = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
        )
        XCTAssertEqual(obj["method"] as? String, "thread/start")
        XCTAssertEqual(obj["jsonrpc"] as? String, "2.0")
        XCTAssertNotNil(obj["id"], "a request must be correlatable")
    }

    func testAResultResolvesTheMatchingRequest() async throws {
        let t = StubTransport()
        let rpc = CodexRPC(transport: t)

        async let result = rpc.request("thread/start", ["cwd": "/w/a"])
        try await Task.sleep(nanoseconds: 50_000_000)
        t.reply(#"{"id":1,"result":{"thread":{"id":"abc"}}}"#)

        let thread = try await (result["thread"] as? [String: Any])
        XCTAssertEqual(thread?["id"] as? String, "abc")
    }

    func testAnErrorResponseThrowsWithTheRemoteMessage() async throws {
        let t = StubTransport()
        let rpc = CodexRPC(transport: t)

        async let result: [String: Any] = rpc.request("thread/name/set", ["threadId": "nope"])
        try await Task.sleep(nanoseconds: 50_000_000)
        t.reply(#"{"id":1,"error":{"code":-32602,"message":"no such thread"}}"#)

        do {
            _ = try await result
            XCTFail("an error response must not resolve")
        } catch CodexRPCError.remote(let code, let message) {
            XCTAssertEqual(code, -32602)
            XCTAssertEqual(message, "no such thread")
        }
    }

    func testNotificationsAreDeliveredSeparatelyFromResponses() {
        let t = StubTransport()
        let rpc = CodexRPC(transport: t)

        var seen: [(String, [String: Any])] = []
        rpc.onNotification = { seen.append(($0, $1)) }
        t.reply(#"{"method":"thread/name/updated","params":{"threadId":"abc","threadName":"x"}}"#)

        XCTAssertEqual(seen.count, 1)
        XCTAssertEqual(seen.first?.0, "thread/name/updated")
        XCTAssertEqual(seen.first?.1["threadName"] as? String, "x")
    }

    func testAClosedTransportFailsPendingRequestsRatherThanHanging() async throws {
        let t = StubTransport()
        let rpc = CodexRPC(transport: t)

        async let result: [String: Any] = rpc.request("thread/start", ["cwd": "/w"])
        try await Task.sleep(nanoseconds: 50_000_000)
        rpc.transportClosed()

        do {
            _ = try await result
            XCTFail("a dead app-server must surface, not hang the tab forever")
        } catch CodexRPCError.transportClosed {}
    }
}
