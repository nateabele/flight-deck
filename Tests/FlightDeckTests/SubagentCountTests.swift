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

    /// The self-heal: a count inherited from attaching mid-turn clears at the boundary.
    func testTurnEndResetsCount() throws {
        let url = dir.appendingPathComponent("t.jsonl")
        var seen: [Int] = []
        let w = start(url) { seen.append($0) }

        try agentStart("a").write(to: url, atomically: true, encoding: .utf8)
        w.drain()
        XCTAssertEqual(seen.last, 1)

        try (agentStart("a") + turnEnd).write(to: url, atomically: true, encoding: .utf8)
        w.drain()

        XCTAssertEqual(seen.last, 0)
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
