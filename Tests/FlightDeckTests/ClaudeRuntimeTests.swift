import XCTest
@testable import FlightDeck

@MainActor
final class ClaudeRuntimeTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func titleLine(_ title: String, _ id: UUID) -> String {
        #"{"type":"custom-title","customTitle":"\#(title)","sessionId":"\#(id.uuidString.lowercased())"}"# + "\n"
    }

    func testAttachForwardsATitleFromTheTranscript() throws {
        let id = UUID()
        let url = dir.appendingPathComponent("t.jsonl")
        let runtime = ClaudeRuntime()

        var seen: [AgentEvent] = []
        runtime.attach(AgentBinding(conversationID: id, transcriptURL: url)) { seen.append($0) }
        runtime.drainForTesting() // prime while the file is still missing, per TranscriptWatcherTests' convention

        try titleLine("renamed", id).write(to: url, atomically: true, encoding: .utf8)
        runtime.drainForTesting()

        XCTAssertEqual(seen, [.title("renamed")])
    }

    func testDetachStopsForwarding() throws {
        let id = UUID()
        let url = dir.appendingPathComponent("t.jsonl")
        let runtime = ClaudeRuntime()

        var seen: [AgentEvent] = []
        let binding = AgentBinding(conversationID: id, transcriptURL: url)
        runtime.attach(binding) { seen.append($0) }
        runtime.detach(binding)

        try titleLine("late", id).write(to: url, atomically: true, encoding: .utf8)
        runtime.drainForTesting()

        XCTAssertTrue(seen.isEmpty, "a detached binding must not receive events")
    }

    func testStatusEntriesBecomeActivityEvents() {
        let id = UUID()
        let runtime = ClaudeRuntime()
        var seen: [AgentEvent] = []
        runtime.attach(AgentBinding(conversationID: id, transcriptURL: nil)) { seen.append($0) }

        // The brief's call site passes `procStart: 1`, but the real initialiser has no
        // Double-typed `procStart` parameter (it takes `startedAt: Double` and a separate
        // `procStart: String = ""`). Adapted to the real signature per the task's
        // instruction to fix the test rather than the type.
        runtime.ingest([4242: ClaudeStatusFile.Entry(
            pid: 4242, sessionID: id, activity: .busy, waitingFor: nil, startedAt: 1
        )])

        XCTAssertEqual(seen, [.activity(.busy)])
    }

    func testTwoTabsOnOneConversationBothReceive() throws {
        let id = UUID()
        let url = dir.appendingPathComponent("shared.jsonl")
        let runtime = ClaudeRuntime()

        var first: [AgentEvent] = []
        var second: [AgentEvent] = []
        let binding = AgentBinding(conversationID: id, transcriptURL: url)
        _ = runtime.attach(binding, for: UUID()) { first.append($0) }
        _ = runtime.attach(binding, for: UUID()) { second.append($0) }
        runtime.drainForTesting()

        try titleLine("renamed", id).write(to: url, atomically: true, encoding: .utf8)
        runtime.drainForTesting()

        XCTAssertEqual(first, [.title("renamed")], "the second attach must not stop the first tab's watcher")
        XCTAssertEqual(second, [.title("renamed")])
    }

    func testDetachingOneOfTwoLeavesTheOtherWatching() throws {
        let id = UUID()
        let url = dir.appendingPathComponent("shared.jsonl")
        let runtime = ClaudeRuntime()

        var first: [AgentEvent] = []
        var second: [AgentEvent] = []
        let binding = AgentBinding(conversationID: id, transcriptURL: url)
        let a = runtime.attach(binding, for: UUID()) { first.append($0) }
        _ = runtime.attach(binding, for: UUID()) { second.append($0) }
        runtime.drainForTesting()

        runtime.detach(a)
        try titleLine("after", id).write(to: url, atomically: true, encoding: .utf8)
        runtime.drainForTesting()

        XCTAssertTrue(first.isEmpty, "a detached subscriber must receive nothing")
        XCTAssertEqual(second, [.title("after")], "the surviving subscriber must keep its watcher")
    }
}
