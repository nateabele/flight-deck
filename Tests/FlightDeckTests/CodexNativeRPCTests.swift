import XCTest
@testable import FlightDeck

@MainActor
final class CodexNativeRPCTests: XCTestCase {
    private final class Transport: CodexTransport {
        var onLine: ((String) -> Void)?
        var sent: [String] = []
        func send(_ line: String) { sent.append(line) }
    }

    func testServerRequestCannotConsumeAnOutgoingRequestWithTheSameID() async throws {
        let transport = Transport()
        let rpc = CodexRPC(transport: transport)
        let task = Task { try await rpc.request("thread/read", ["threadId": "t"]) }
        await Task.yield()
        transport.onLine?(#"{"id":1,"method":"item/tool/requestUserInput","params":{"threadId":"t"}}"#)
        XCTAssertEqual(rpc.pendingCount, 1, "server and client request ids occupy different namespaces")
        transport.onLine?(#"{"id":1,"result":{"thread":{"id":"t"}}}"#)
        let result = try await task.value
        XCTAssertEqual((result["thread"] as? [String: Any])?["id"] as? String, "t")
    }

    func testMetadataLookupTimeoutRetiresTheOutgoingRequest() async throws {
        let transport = Transport()
        let rpc = CodexRPC(transport: transport)
        do {
            _ = try await rpc.request("thread/read", ["threadId": "missing"], timeoutSeconds: 0.01)
            XCTFail("an unanswered lookup must time out")
        } catch { XCTAssertEqual(error as? CodexRPCError, .timeout) }
        XCTAssertEqual(rpc.pendingCount, 0)
    }
}
