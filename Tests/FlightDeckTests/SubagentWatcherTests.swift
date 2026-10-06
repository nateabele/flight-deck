import XCTest
@testable import FlightDeck

@MainActor
final class SubagentWatcherTests: XCTestCase {
    private var dir: URL!
    private var clockNow = Date(timeIntervalSince1970: 3_000_000)

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func write(_ id: String, type: String = "implementer", parent: String? = nil,
                       records: [String]) throws {
        let parentKey = parent.map { #","parentAgentId":"\#($0)""# } ?? ""
        try #"{"agentType":"\#(type)","description":"d \#(id)","toolUseId":"toolu_\#(id)"\#(parentKey),"spawnDepth":1}"#
            .write(to: dir.appendingPathComponent("agent-\(id).meta.json"), atomically: true, encoding: .utf8)
        try (records.joined(separator: "\n") + "\n")
            .write(to: dir.appendingPathComponent("agent-\(id).jsonl"), atomically: false, encoding: .utf8)
    }
    private let open = #"{"isSidechain":true,"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_1","name":"Bash","input":{"command":"ls"}}]}}"#
    private let finished = #"{"isSidechain":true,"type":"assistant","message":{"role":"assistant","stop_reason":"end_turn","content":[{"type":"text","text":"done"}]}}"#

    private func makeWatcher(_ seen: @escaping (SubagentTree) -> Void) -> SubagentWatcher {
        let w = SubagentWatcher(directory: dir, clock: nil, startedAt: { nil },
                                keepDoneSince: { nil }, onChange: seen)
        w.now = { [unowned self] in self.clockNow }
        return w
    }

    func testAScanBuildsTheTreeAndReportsIt() throws {
        try write("a0aaaaaa", type: "general-purpose", records: [open])
        try write("a1bbbbbb", parent: "a0aaaaaa", records: [open])
        var seen: [SubagentTree] = []
        let w = makeWatcher { seen.append($0) }
        w.rescan()
        XCTAssertEqual(seen.last?.nodes.count, 2)
        XCTAssertEqual(seen.last?.node("a1bbbbbb")?.parentID, "a0aaaaaa")
        XCTAssertEqual(seen.last?.liveTopLevelCount, 1)
    }

    func testAnAppendThatFinishesAnAgentIsReported() throws {
        try write("a0aaaaaa", records: [open])
        var seen: [SubagentTree] = []
        let w = makeWatcher { seen.append($0) }
        w.rescan()
        let h = try FileHandle(forWritingTo: dir.appendingPathComponent("agent-a0aaaaaa.jsonl"))
        try h.seekToEnd(); try h.write(contentsOf: Data((finished + "\n").utf8)); try h.close()
        w.poll()
        XCTAssertEqual(seen.last?.node("a0aaaaaa")?.state, .done)
    }

    func testFilesFromBeforeTheProcessStartedAreIgnored() throws {
        try write("a0aaaaaa", records: [open])
        let w = SubagentWatcher(directory: dir, clock: nil,
                                startedAt: { Date().addingTimeInterval(60) },
                                keepDoneSince: { nil }, onChange: { _ in })
        w.rescan()
        XCTAssertTrue(w.tree.nodes.isEmpty)
    }

    /// Review Focus 5: a steady tick must not stat every file in a 200-file folder.
    func testASteadyTickStatsOnlyLiveFiles() throws {
        for i in 0..<20 { try write(String(format: "a%07x", i + 0x100), records: [finished]) }
        try write("a0aaaaaa", records: [open])
        let w = makeWatcher { _ in }
        w.rescan()
        w.poll()
        XCTAssertLessThanOrEqual(w.statCount, 2, "the live file plus the folder, not 21 files")
        clockNow = clockNow.addingTimeInterval(SubagentWatcher.fullRescanInterval + 1)
        w.poll()
        XCTAssertGreaterThanOrEqual(w.statCount, 21, "a periodic full rescan still runs")
    }

    func testANewFileIsFoundOnTheNextTick() throws {
        let w = makeWatcher { _ in }
        w.rescan()
        // Creating a file changes the folder's own stamp, which `poll` compares every tick.
        try write("a0aaaaaa", records: [open])
        w.poll()
        XCTAssertEqual(w.tree.nodes.count, 1)
    }
}
