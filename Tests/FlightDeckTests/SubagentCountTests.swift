import XCTest
@testable import FlightDeck

@MainActor
final class SubagentCountTests: XCTestCase {
    private var dir: URL!
    private let sid = UUID()

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func start(_ url: URL, counts: @escaping (Int) -> Void) -> TranscriptWatcher {
        FileManager.default.createFile(atPath: url.path, contents: Data())
        let w = TranscriptWatcher(
            sessionID: sid, url: url, onTitle: { _ in }, onSubagentCount: counts
        )
        w.drain() // prime while empty, mirroring production
        return w
    }

    private func agentStart(_ id: String) -> String {
        #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"\#(id)","name":"Agent"}]}}"# + "\n"
    }

    private func toolResult(_ id: String) -> String {
        #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"\#(id)"}]}}"# + "\n"
    }

    private let turnEnd = #"{"type":"system","subtype":"turn_duration"}"# + "\n"

    func testCountsOutstandingAgents() throws {
        let url = dir.appendingPathComponent("t.jsonl")
        var seen: [Int] = []
        let w = start(url) { seen.append($0) }

        try (agentStart("a") + agentStart("b")).write(to: url, atomically: true, encoding: .utf8)
        w.drain()

        XCTAssertEqual(seen.last, 2)
    }

    func testFinishedAgentDecrementsCount() throws {
        let url = dir.appendingPathComponent("t.jsonl")
        var seen: [Int] = []
        let w = start(url) { seen.append($0) }

        try (agentStart("a") + agentStart("b")).write(to: url, atomically: true, encoding: .utf8)
        w.drain()
        try (agentStart("a") + agentStart("b") + toolResult("a"))
            .write(to: url, atomically: true, encoding: .utf8)
        w.drain()

        XCTAssertEqual(seen.last, 1)
    }

    /// The launch's result, with the agent id claude assigns it — `agent-<id>` for `<id>`.
    private func asyncLaunched(_ id: String) -> String {
        #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"\#(id)"}]},"toolUseResult":{"isAsync":true,"status":"async_launched","agentId":"agent-\#(id)"}}"# + "\n"
    }

    private func notification(_ id: String, task: String? = nil) -> String {
        let task = task ?? "agent-\(id)"
        return #"{"type":"user","message":{"role":"user","content":"<task-notification>\\n<task-id>\#(task)</task-id>\\n<tool-use-id>\#(id)</tool-use-id>\\n<status>completed</status>\\n</task-notification>"}}"# + "\n"
    }

    /// An agent continued via `SendMessage` before its first stop reports under the
    /// continuing call's tool-use id; only its task id still names the launch. 10 of 1211
    /// launches across 80 real transcripts closed only this way.
    func testNotificationClosesByAgentIDWhenToolUseIDDiffers() throws {
        let url = dir.appendingPathComponent("t.jsonl")
        var seen: [Int] = []
        let w = start(url) { seen.append($0) }

        var file = agentStart("a") + asyncLaunched("a")
        try file.write(to: url, atomically: true, encoding: .utf8)
        w.drain()
        XCTAssertEqual(seen.last, 1)

        file += notification("toolu_sendmessage", task: "agent-a")
        try file.write(to: url, atomically: true, encoding: .utf8)
        w.drain()
        XCTAssertEqual(seen.last, 0)
    }

    private func resumed(_ toolUseID: String, agent: String) -> String {
        #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"\#(toolUseID)"}]},"toolUseResult":{"success":true,"resumedAgentId":"\#(agent)"}}"# + "\n"
    }

    /// A stopped agent woken by `SendMessage` is working again until its next notification.
    func testResumedAgentCountsUntilItStopsAgain() throws {
        let url = dir.appendingPathComponent("t.jsonl")
        var seen: [Int] = []
        let w = start(url) { seen.append($0) }

        var file = agentStart("a") + asyncLaunched("a") + notification("a")
        try file.write(to: url, atomically: true, encoding: .utf8)
        w.drain()
        file += resumed("toolu_sm", agent: "agent-a")
        try file.write(to: url, atomically: true, encoding: .utf8)
        w.drain()
        XCTAssertEqual(seen.last, 1)

        file += notification("toolu_sm", task: "agent-a")
        try file.write(to: url, atomically: true, encoding: .utf8)
        w.drain()
        XCTAssertEqual(seen.last, 0)
    }

    /// Messaging an agent that is still running is not a second agent.
    func testResumingARunningAgentDoesNotDoubleCount() throws {
        let url = dir.appendingPathComponent("t.jsonl")
        var seen: [Int] = []
        let w = start(url) { seen.append($0) }

        try (agentStart("a") + asyncLaunched("a") + resumed("toolu_sm", agent: "agent-a"))
            .write(to: url, atomically: true, encoding: .utf8)
        w.drain()
        XCTAssertEqual(seen.last, 1)
    }

    /// A notification for an agent this watcher never saw launch — it attached after the
    /// launch, or compaction dropped it — must not push the count down for agents it did see.
    func testNotificationForUnseenLaunchChangesNothing() throws {
        let url = dir.appendingPathComponent("t.jsonl")
        var seen: [Int] = []
        let w = start(url) { seen.append($0) }

        var file = agentStart("a") + asyncLaunched("a")
        try file.write(to: url, atomically: true, encoding: .utf8)
        w.drain()
        XCTAssertEqual(seen, [1])

        file += notification("never-seen")
        try file.write(to: url, atomically: true, encoding: .utf8)
        w.drain()
        XCTAssertEqual(seen, [1], "no change means no callback")
    }

    /// The regression: launch and its "launched" result land in the same poll, and the count
    /// must survive it.
    func testAsyncLaunchKeepsCountUntilNotification() throws {
        let url = dir.appendingPathComponent("t.jsonl")
        var seen: [Int] = []
        let w = start(url) { seen.append($0) }

        var file = agentStart("a") + asyncLaunched("a") + agentStart("b") + asyncLaunched("b")
        try file.write(to: url, atomically: true, encoding: .utf8)
        w.drain()
        XCTAssertEqual(seen.last, 2)

        file += notification("a")
        try file.write(to: url, atomically: true, encoding: .utf8)
        w.drain()
        XCTAssertEqual(seen.last, 1)

        file += notification("b")
        try file.write(to: url, atomically: true, encoding: .utf8)
        w.drain()
        XCTAssertEqual(seen.last, 0)
    }

    /// A background agent outlives the turn that launched it, so the turn boundary must not
    /// clear it.
    func testTurnEndDoesNotClearBackgroundAgents() throws {
        let url = dir.appendingPathComponent("t.jsonl")
        var seen: [Int] = []
        let w = start(url) { seen.append($0) }

        var file = agentStart("a") + asyncLaunched("a")
        try file.write(to: url, atomically: true, encoding: .utf8)
        w.drain()
        XCTAssertEqual(seen.last, 1)

        file += turnEnd
        try file.write(to: url, atomically: true, encoding: .utf8)
        w.drain()

        XCTAssertEqual(seen.last, 1)
    }

    func testUnknownToolResultDoesNotReport() throws {
        let url = dir.appendingPathComponent("t.jsonl")
        var seen: [Int] = []
        let w = start(url) { seen.append($0) }

        try toolResult("never-started").write(to: url, atomically: true, encoding: .utf8)
        w.drain()

        XCTAssertTrue(seen.isEmpty, "no change means no callback")
    }

    func testTitleStillReported() throws {
        let url = dir.appendingPathComponent("t.jsonl")
        FileManager.default.createFile(atPath: url.path, contents: Data())
        var titles: [String] = []
        let w = TranscriptWatcher(sessionID: sid, url: url, onTitle: { titles.append($0) })
        w.drain()

        let line = #"{"type":"custom-title","customTitle":"renamed","sessionId":"\#(sid.uuidString.lowercased())"}"# + "\n"
        try line.write(to: url, atomically: true, encoding: .utf8)
        w.drain()

        XCTAssertEqual(titles, ["renamed"])
    }
}
