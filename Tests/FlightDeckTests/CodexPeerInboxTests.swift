import XCTest
@testable import FlightDeck

@MainActor
final class CodexPeerInboxTests: XCTestCase {
    /// Answers `thread/read` with each of `statuses` in turn (the last one repeats) and records
    /// every request.
    private final class DaemonTransport: CodexTransport {
        var onLine: ((String) -> Void)?
        var statuses: [String]
        private(set) var requests: [(method: String, params: [String: Any])] = []
        init(_ statuses: [String]) { self.statuses = statuses }
        func send(_ line: String) {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let method = obj["method"] as? String, let id = obj["id"] as? Int else { return }
            requests.append((method, obj["params"] as? [String: Any] ?? [:]))
            if method == "thread/read" {
                let status = statuses.count > 1 ? statuses.removeFirst() : statuses[0]
                onLine?(#"{"id":\#(id),"result":{"thread":{"status":{"type":"\#(status)"}}}}"#)
            } else {
                onLine?(#"{"id":\#(id),"result":{}}"#)
            }
        }
    }

    private var rollout: URL!

    override func setUpWithError() throws {
        rollout = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("rollout-\(UUID()).jsonl")
        try Data().write(to: rollout)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: rollout) }

    private func inbox(_ transport: DaemonTransport) -> CodexPeerInbox {
        var inbox = CodexPeerInbox(rpc: CodexRPC(transport: transport), thread: UUID(), rollout: rollout)
        inbox.pollInterval = .milliseconds(10)
        return inbox
    }

    private func line(_ payload: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: ["type": "response_item", "payload": payload])
        return String(decoding: data, as: UTF8.self)
    }

    func testAnIdleTabGetsTheMessageAsAToolResultAndAnEmptyTurn() async throws {
        let transport = DaemonTransport(["idle"])
        let outcome = try await inbox(transport).deliver(id: "ABC-1", text: "<cross-session-message>hi</cross-session-message>")
        XCTAssertEqual(outcome, .delivered)
        XCTAssertEqual(transport.requests.map(\.method), ["thread/read", "thread/inject_items", "turn/start"])
        let items = try XCTUnwrap(transport.requests[1].params["items"] as? [[String: Any]])
        XCTAssertEqual(items.map { $0["type"] as? String }, ["function_call", "function_call_output"])
        XCTAssertEqual(items[0]["name"] as? String, "ReceiveMessages")
        XCTAssertEqual(items[1]["call_id"] as? String, CodexPeerInbox.callID(for: "ABC-1"))
        XCTAssertEqual(items[1]["output"] as? String, "<cross-session-message>hi</cross-session-message>")
        XCTAssertEqual((transport.requests[2].params["input"] as? [Any])?.count, 0, "no user text is submitted")
    }

    func testANotLoadedThreadIsLeftToTheTypedPath() async throws {
        let transport = DaemonTransport(["notLoaded"])
        let outcome = try await inbox(transport).deliver(id: "ABC-2", text: "hi")
        XCTAssertEqual(outcome, .notAttached)
        XCTAssertEqual(transport.requests.map(\.method), ["thread/read"])
    }

    /// A retry after a crash finds the first injection in the rollout and only wakes.
    func testARecordedMessageIsNotInjectedTwice() async throws {
        let call = CodexPeerInbox.callID(for: "ABC-3")
        try (line(["type": "function_call_output", "call_id": call, "output": "hi"]) + "\n").write(to: rollout, atomically: true, encoding: .utf8)
        let transport = DaemonTransport(["idle"])
        _ = try await inbox(transport).deliver(id: "ABC-3", text: "hi")
        XCTAssertEqual(transport.requests.map(\.method), ["thread/read", "turn/start"])
    }

    /// A busy turn that ended without reading the message gets one empty turn to read it.
    func testABusyTurnThatNeverReadItIsWokenWhenIdle() async throws {
        let transport = DaemonTransport(["active", "active", "idle"])
        let call = CodexPeerInbox.callID(for: "ABC-4")
        try (line(["type": "function_call_output", "call_id": call, "output": "hi"]) + "\n").write(to: rollout, atomically: true, encoding: .utf8)
        _ = try await inbox(transport).deliver(id: "ABC-4", text: "hi")
        for _ in 0..<200 where !transport.requests.contains(where: { $0.method == "turn/start" }) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(transport.requests.filter { $0.method == "turn/start" }.count, 1)
    }

    func testAnsweredMeansModelOutputAfterTheInjectedResult() {
        let call = CodexPeerInbox.callID(for: "ABC-5")
        let injected = line(["type": "function_call_output", "call_id": call, "output": "hi"])
        XCTAssertFalse(CodexPeerInbox.answered(call, lines: [injected]))
        XCTAssertFalse(CodexPeerInbox.answered(call, lines: [
            injected, line(["type": "function_call", "name": "ReceiveMessages", "call_id": "call_peer_other"]),
        ]), "a later peer message is not the model reading this one")
        XCTAssertTrue(CodexPeerInbox.answered(call, lines: [
            injected, line(["type": "message", "role": "assistant", "content": []]),
        ]))
        XCTAssertFalse(CodexPeerInbox.answered(call, lines: [
            line(["type": "message", "role": "assistant", "content": []]), injected,
        ]), "output before the message does not count")
    }
}
