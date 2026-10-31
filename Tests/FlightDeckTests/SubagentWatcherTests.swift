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
        // A known start well in the past: an unknown one reads nothing at all (see
        // `testAnUnknownProcessStartReadsNoFilesAndPublishesNothing`).
        let w = SubagentWatcher(directory: dir, clock: nil, startedAt: { .distantPast },
                                keepDoneSince: { nil }, onChange: seen)
        w.now = { [unowned self] in self.clockNow }
        return w
    }

    /// The clock's beat runs on the main queue, and so does every phone request the fleet
    /// server answers. A tick must hand the folder listing off and return, or 65 sessions'
    /// scans hold the phone's requests for as long as the disk takes (44s measured).
    func testATickScansOffTheMainThreadAndPublishesOnIt() async throws {
        try write("a0aaaaaa", records: [open])
        let clock = WatchClock(appIsActive: { true })
        let published = expectation(description: "published")
        var publishedOnMain: Bool?
        let w = SubagentWatcher(directory: dir, clock: clock, startedAt: { .distantPast },
                                keepDoneSince: { nil }, onChange: { _ in
                                    publishedOnMain = Thread.isMainThread
                                    published.fulfill()
                                })
        w.start()
        clock.fire()
        XCTAssertTrue(w.tree.nodes.isEmpty, "the tick returns before the scan has run")
        await fulfillment(of: [published], timeout: 5)
        XCTAssertEqual(publishedOnMain, true)
        XCTAssertEqual(w.lastScanRanOnMain, false)
        XCTAssertEqual(w.tree.nodes.count, 1)
        w.stop()
    }

    /// A rescan asked for while a scan is in flight is run after it, not dropped: the fold
    /// asks for one when it sees a launch, and losing it would leave the tree a launch behind.
    func testARescanRequestedMidScanRunsAfterIt() async throws {
        let clock = WatchClock(appIsActive: { true })
        var trees: [SubagentTree] = []
        let second = expectation(description: "second publish")
        let w = SubagentWatcher(directory: dir, clock: clock, startedAt: { .distantPast },
                                keepDoneSince: { nil }, onChange: { tree in
                                    trees.append(tree)
                                    if tree.nodes.count == 1 { second.fulfill() }
                                })
        w.requestRescan()
        try write("a0aaaaaa", records: [open])
        w.requestRescan()
        await fulfillment(of: [second], timeout: 5)
        XCTAssertEqual(w.tree.nodes.count, 1)
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
        // A finished agent resumed behind the tick's back: only a full rescan can see it.
        try append(open, to: "a0000100")
        w.poll()
        XCTAssertEqual(w.tree.node("a0000100")?.state, .done, "not noticed by a steady tick")
        clockNow = clockNow.addingTimeInterval(SubagentWatcher.fullRescanInterval + 1)
        w.poll()
        XCTAssertEqual(w.tree.node("a0000100")?.state, .running, "a periodic full rescan still runs")
    }

    private func append(_ record: String, to id: String) throws {
        let h = try FileHandle(forWritingTo: dir.appendingPathComponent("agent-\(id).jsonl"))
        try h.seekToEnd(); try h.write(contentsOf: Data((record + "\n").utf8)); try h.close()
    }

    /// The listing already carries each file's size and mtime: a file older than the process
    /// start is dropped from it, and an unchanged one reuses its stamp. Neither costs a stat.
    func testARescanStatsNoFileTheListingCanVouchFor() throws {
        for i in 0..<20 { try write(String(format: "a%07x", i + 0x100), records: [finished]) }
        let old = SubagentWatcher(directory: dir, clock: nil, startedAt: { Date().addingTimeInterval(60) },
                                  keepDoneSince: { nil }, onChange: { _ in })
        old.rescan()
        XCTAssertEqual(old.statCount, 1, "the folder only: every file predates the start")
        XCTAssertTrue(old.tree.nodes.isEmpty)

        let w = makeWatcher { _ in }
        w.rescan()
        XCTAssertEqual(w.tree.nodes.count, 20)
        let reads = w.tailReadCount
        w.rescan()
        XCTAssertEqual(w.statCount, 1, "unchanged files reuse their stamps")
        XCTAssertEqual(w.tailReadCount, reads)
    }

    /// `poll` stamps a live file with `stat`, `rescan` with the listing: they must agree, or
    /// every live file would be re-read on the first tick after each rescan.
    func testAListedStampEqualsAStatStamp() throws {
        for i in 0..<5 { try write(String(format: "a%07x", i + 0x100), records: [finished, open]) }
        let listed = DirectoryStamps.list(dir)
        XCTAssertEqual(listed.count, 10, "five transcripts and five metas")
        for (name, stamp) in listed {
            XCTAssertEqual(stamp, TranscriptStamp(of: dir.appendingPathComponent(name)), name)
        }
    }

    /// What the listing-based shortcut must not hide: an append, an in-place rewrite and a
    /// replacement (new inode) of a finished agent's file are each seen by the next rescan.
    func testARescanStillSeesAnAppendARewriteAndAReplace() throws {
        try write("a0aaaaaa", records: [finished])
        try write("a1bbbbbb", records: [finished])
        try write("a2cccccc", records: [finished])
        let w = makeWatcher { _ in }
        w.rescan()
        XCTAssertEqual(w.tree.node("a0aaaaaa")?.state, .done)

        try append(open, to: "a0aaaaaa")
        let rewritten = dir.appendingPathComponent("agent-a1bbbbbb.jsonl")
        let h = try FileHandle(forWritingTo: rewritten)
        try h.truncate(atOffset: 0); try h.write(contentsOf: Data((open + "\n").utf8)); try h.close()
        let staged = dir.appendingPathComponent("staged.tmp")
        try (open + "\n").write(to: staged, atomically: false, encoding: .utf8)
        _ = try FileManager.default.replaceItemAt(
            dir.appendingPathComponent("agent-a2cccccc.jsonl"), withItemAt: staged)
        w.rescan()
        for id in ["a0aaaaaa", "a1bbbbbb", "a2cccccc"] {
            XCTAssertEqual(w.tree.node(id)?.state, .running, id)
        }
    }

    /// With nothing live the full rescan backs off, but a new file (the folder's stamp) is
    /// seen at once and a resumed agent within the slow interval.
    func testAnIdleConversationRescansSlowlyButAFolderChangeBypassesIt() throws {
        try write("a0aaaaaa", records: [finished])
        let w = makeWatcher { _ in }
        w.rescan()
        try append(open, to: "a0aaaaaa")
        clockNow = clockNow.addingTimeInterval(SubagentWatcher.fullRescanInterval + 1)
        w.poll()
        XCTAssertEqual(w.tree.node("a0aaaaaa")?.state, .done, "no rescan yet: nothing is live")
        try write("a1bbbbbb", records: [finished])
        w.poll()
        XCTAssertNotNil(w.tree.node("a1bbbbbb"), "a folder change rescans at once")
        XCTAssertEqual(w.tree.node("a0aaaaaa")?.state, .running, "and that rescan saw the resume")

        try append(finished, to: "a0aaaaaa")
        w.poll()
        try append(open, to: "a1bbbbbb")
        clockNow = clockNow.addingTimeInterval(SubagentWatcher.idleRescanInterval + 1)
        w.poll()
        XCTAssertEqual(w.tree.node("a1bbbbbb")?.state, .running, "noticed within the idle interval")
    }

    func testANewFileIsFoundOnTheNextTick() throws {
        let w = makeWatcher { _ in }
        w.rescan()
        // Creating a file changes the folder's own stamp, which `poll` compares every tick.
        try write("a0aaaaaa", records: [open])
        w.poll()
        XCTAssertEqual(w.tree.nodes.count, 1)
    }

    /// Before the first registry row pins the tab, and always after claude exits (a dead pid
    /// has no start), the start is unknown. Read as "all history" that showed half-finished
    /// agents from earlier runs as running and tail-read every file on the main actor.
    func testAnUnknownProcessStartReadsNoFilesAndPublishesNothing() throws {
        for i in 0..<5 { try write(String(format: "a%07x", i + 0x100), records: [open]) }
        var seen: [SubagentTree] = []
        let w = SubagentWatcher(directory: dir, clock: nil, startedAt: { nil },
                                keepDoneSince: { nil }, onChange: { seen.append($0) })
        w.now = { [unowned self] in self.clockNow }
        w.rescan()
        w.poll()
        XCTAssertTrue(w.tree.nodes.isEmpty)
        XCTAssertTrue(seen.isEmpty)
        XCTAssertEqual(w.tailReadCount, 0)
    }

    func testATreeIsKeptWhenTheStartBecomesUnknown() throws {
        try write("a0aaaaaa", records: [open])
        var start: Date? = .distantPast
        var seen: [SubagentTree] = []
        let w = SubagentWatcher(directory: dir, clock: nil, startedAt: { start },
                                keepDoneSince: { nil }, onChange: { seen.append($0) })
        w.now = { [unowned self] in self.clockNow }
        w.rescan()
        XCTAssertEqual(w.tree.node("a0aaaaaa")?.state, .running)
        let reads = w.tailReadCount
        start = nil
        let h = try FileHandle(forWritingTo: dir.appendingPathComponent("agent-a0aaaaaa.jsonl"))
        try h.seekToEnd(); try h.write(contentsOf: Data((finished + "\n").utf8)); try h.close()
        w.poll()
        clockNow = clockNow.addingTimeInterval(SubagentWatcher.fullRescanInterval + 1)
        w.poll()
        XCTAssertEqual(w.tree.node("a0aaaaaa")?.state, .running, "the last tree, unchanged")
        XCTAssertEqual(seen.count, 1)
        XCTAssertEqual(w.tailReadCount, reads)
    }

    func testATreeIsBuiltOnTheFirstTickAfterTheStartIsKnown() throws {
        try write("a0aaaaaa", records: [open])
        var start: Date?
        let w = SubagentWatcher(directory: dir, clock: nil, startedAt: { start },
                                keepDoneSince: { nil }, onChange: { _ in })
        w.now = { [unowned self] in self.clockNow }
        w.poll()
        XCTAssertTrue(w.tree.nodes.isEmpty)
        start = .distantPast
        w.poll()
        XCTAssertEqual(w.tree.nodes.count, 1)
    }
}
