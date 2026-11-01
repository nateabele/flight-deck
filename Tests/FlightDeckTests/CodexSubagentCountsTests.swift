import XCTest
@testable import FlightDeck

final class CodexSubagentCountsTests: XCTestCase {
    private func thread(_ id: UUID, parent: UUID, status: String = "active") -> [String: Any] {
        ["id": id.uuidString, "parentThreadId": parent.uuidString,
         "status": ["type": status, "activeFlags": ["waitingOnApproval"]]]
    }

    func testActiveDescendantsIncludeBlockedAndNestedWorkersButNotOtherSessions() {
        let root = UUID(), child = UUID(), nested = UUID(), other = UUID()
        var counts = CodexSubagentCounts()
        for info in [thread(child, parent: root), thread(nested, parent: child), thread(UUID(), parent: other)] {
            _ = counts.receive("thread/started", params: ["thread": info])
        }
        XCTAssertEqual(counts.count(for: root), 2)
        XCTAssertEqual(counts.count(for: child), 1)
        _ = counts.receive("thread/status/changed", params: ["threadId": child.uuidString, "status": ["type": "idle"]])
        XCTAssertEqual(counts.count(for: root), 1)
        _ = counts.receive("thread/closed", params: ["threadId": nested.uuidString])
        XCTAssertEqual(counts.count(for: root), 0)
    }

    func testCollaborationStatesAreIdempotentAndPeerRecipientsAreNotAdopted() {
        let root = UUID(), child = UUID(), peer = UUID()
        var counts = CodexSubagentCounts()
        var item: [String: Any] = ["type": "collabAgentToolCall", "tool": "spawnAgent", "senderThreadId": root.uuidString,
            "receiverThreadIds": [child.uuidString], "status": "completed", "agentsStates": [child.uuidString: ["status": "running"]]]
        for _ in 0..<2 { _ = counts.receive("item/completed", params: ["item": item]) }
        XCTAssertEqual(counts.count(for: root), 1)
        item["tool"] = "sendMessage"
        item["receiverThreadIds"] = [peer.uuidString]
        item["agentsStates"] = [peer.uuidString: ["status": "running"]]
        _ = counts.receive("item/completed", params: ["item": item])
        XCTAssertEqual(counts.count(for: root), 1)
        item["tool"] = "wait"
        item["agentsStates"] = [child.uuidString: ["status": "completed"]]
        _ = counts.receive("item/completed", params: ["item": item])
        XCTAssertEqual(counts.count(for: root), 0)
        item["tool"] = "resumeAgent"
        item["agentsStates"] = [child.uuidString: ["status": "pendingInit"]]
        _ = counts.receive("item/completed", params: ["item": item])
        XCTAssertEqual(counts.count(for: root), 1)
    }

    func testSnapshotRestoresAndClearsCountsWithoutResurrectingNewerCompletions() {
        let root = UUID(), child = UUID()
        var counts = CodexSubagentCounts()
        counts.reconcile(root: root, threads: [thread(child, parent: root)], through: counts.revision)
        XCTAssertEqual(counts.count(for: root), 1)
        let cutoff = counts.revision
        _ = counts.receive("turn/completed", params: ["threadId": child.uuidString])
        counts.reconcile(root: root, threads: [thread(child, parent: root)], through: cutoff)
        XCTAssertEqual(counts.count(for: root), 0)
        _ = counts.receive("turn/started", params: ["threadId": child.uuidString])
        counts.reconcile(root: root, threads: [], through: counts.revision)
        XCTAssertEqual(counts.count(for: root), 0)
    }

    func testSnapshotDoesNotEraseANewSpawnThatArrivesDuringTheQuery() {
        let root = UUID(), child = UUID()
        var counts = CodexSubagentCounts()
        let cutoff = counts.revision
        _ = counts.receive("thread/started", params: ["thread": thread(child, parent: root)])
        counts.reconcile(root: root, threads: [], through: cutoff)
        XCTAssertEqual(counts.count(for: root), 1)
    }

    func testRepeatedCompletionStillOverridesAnOlderActiveSnapshot() {
        let root = UUID(), child = UUID()
        var counts = CodexSubagentCounts()
        counts.reconcile(root: root, threads: [thread(child, parent: root, status: "idle")], through: 0)
        let cutoff = counts.revision
        _ = counts.receive("turn/completed", params: ["threadId": child.uuidString])
        counts.reconcile(root: root, threads: [thread(child, parent: root)], through: cutoff)
        XCTAssertEqual(counts.count(for: root), 0)
    }

    func testSourceAncestryWorksAndCyclesDoNotHang() {
        let root = UUID(), child = UUID()
        var counts = CodexSubagentCounts()
        counts.reconcile(root: root, threads: [["id": child.uuidString,
            "source": ["subAgent": ["thread_spawn": ["parent_thread_id": root.uuidString]]],
            "status": ["type": "active"]]], through: 0)
        XCTAssertEqual(counts.count(for: root), 1)
        let a = UUID(), b = UUID()
        for info in [thread(a, parent: b), thread(b, parent: a)] {
            _ = counts.receive("thread/started", params: ["thread": info])
        }
        XCTAssertEqual(counts.count(for: root), 1)
    }
}
