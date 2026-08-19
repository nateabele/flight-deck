import XCTest
@testable import FlightDeck

@MainActor
final class CodexRuntimeTests: XCTestCase {
    final class NullTransport: CodexTransport {
        var onLine: ((String) -> Void)?
        func send(_ line: String) {}
    }

    private func makeRuntime() -> CodexRuntime {
        CodexRuntime(rpc: CodexRPC(transport: NullTransport()))
    }

    private let threadID = UUID(uuidString: "01a01269-baa6-7493-8d15-8fa21bcb602b")!

    func testNotificationsReachOnlyTheMatchingAttachment() {
        let runtime = makeRuntime()
        var mine: [AgentEvent] = []
        var theirs: [AgentEvent] = []
        runtime.attach(AgentBinding(conversationID: threadID, transcriptURL: nil)) { mine.append($0) }
        runtime.attach(AgentBinding(conversationID: UUID(), transcriptURL: nil)) { theirs.append($0) }

        runtime.handle(method: "thread/name/updated",
                       params: ["threadId": threadID.uuidString.lowercased(), "threadName": "x"])

        XCTAssertEqual(mine, [.title("x")])
        XCTAssertTrue(theirs.isEmpty, "notifications are multiplexed by threadId, not broadcast")
    }

    func testFirstContactTriggersExactlyOneReconcile() async {
        let runtime = makeRuntime()
        var reconciled: [UUID] = []
        runtime.reconcile = { reconciled.append($0) }
        runtime.attach(AgentBinding(conversationID: threadID, transcriptURL: nil)) { _ in }

        let id = threadID.uuidString.lowercased()
        // A session that launched behind the hooks-review prompt reports nothing until the
        // user clears it. The first notification of ANY kind is the cue to re-read
        // authoritative title and status — once, not on every notification.
        runtime.handle(method: "turn/started", params: ["threadId": id])
        runtime.handle(method: "turn/completed", params: ["threadId": id])
        await Task.yield()

        XCTAssertEqual(reconciled, [threadID])
    }

    func testDetachStopsRouting() {
        let runtime = makeRuntime()
        var seen: [AgentEvent] = []
        let binding = AgentBinding(conversationID: threadID, transcriptURL: nil)
        runtime.attach(binding) { seen.append($0) }
        runtime.detach(binding)

        runtime.handle(method: "thread/name/updated",
                       params: ["threadId": threadID.uuidString.lowercased(), "threadName": "x"])

        XCTAssertTrue(seen.isEmpty)
    }
}
