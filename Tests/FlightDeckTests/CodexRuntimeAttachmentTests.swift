import XCTest
@testable import FlightDeck

@MainActor
final class CodexRuntimeAttachmentTests: XCTestCase {
    private var dir: URL!
    private var index: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        index = dir.appendingPathComponent("session_index.jsonl")
        FileManager.default.createFile(atPath: index.path, contents: Data())
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func rollout(named name: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        FileManager.default.createFile(atPath: url.path, contents: Data())
        return url
    }

    private func append(_ text: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    private func indexLine(_ id: UUID, _ name: String) -> String {
        #"{"id":"\#(id.uuidString.lowercased())","thread_name":"\#(name)"}"# + "\n"
    }

    private let turn = #"{"type":"event_msg","payload":{"type":"task_started"}}"# + "\n"

    func testJoiningAnAlreadyBusyThreadReceivesItsCurrentStatus() {
        let runtime = CodexRuntime(indexURL: index)
        let id = UUID()
        let binding = AgentBinding(conversationID: id, transcriptURL: nil)
        let first = runtime.attach(binding, for: UUID()) { _ in }
        runtime.receiveNativeStatus(thread: id, activity: .busy)
        var seen: [AgentEvent] = []
        let second = runtime.attach(binding, for: UUID()) { seen.append($0) }
        runtime.receiveNativeStatus(thread: id, activity: .busy)
        XCTAssertEqual(seen.last, .activity(.busy))
        runtime.detach(first)
        runtime.detach(second)
    }

    private final class StatusTransport: CodexTransport {
        var onLine: ((String) -> Void)?
        var methods: [String] = []
        var status: [String: Any] = ["type": "active", "activeFlags": []]
        func send(_ line: String) {
            let request = try! JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]
            methods.append(request["method"] as! String)
            let reply: [String: Any] = ["id": request["id"]!, "result": ["thread": ["status": status]]]
            onLine?(String(decoding: try! JSONSerialization.data(withJSONObject: reply), as: UTF8.self))
        }
    }

    func testConnectingAfterTabsAttachRecoversWorkingStatusAndMissedNotifications() async throws {
        let runtime = CodexRuntime(indexURL: index)
        let transport = StatusTransport()
        let dialogs = CodexNativeDialogs(rpc: CodexRPC(transport: transport))
        dialogs.onChange = { [weak runtime] in runtime?.receiveNativeStatus(thread: $0, activity: $1) }
        var stamp = Date()
        runtime.now = { stamp }
        var seen: [AgentEvent] = []
        let token = runtime.attach(AgentBinding(conversationID: UUID(), transcriptURL: nil), for: UUID()) { seen.append($0) }
        XCTAssertTrue(transport.methods.isEmpty)
        runtime.nativeDialogs = dialogs
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(seen.last, .activity(.busy), "tabs attached before initialize must rejoin once ready")
        transport.status = ["type": "idle"]
        stamp.addTimeInterval(6)
        runtime.drainForTesting()
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(seen.last, .activity(.idle), "metadata reconciles a transition whose notification was missed")
        XCTAssertEqual(transport.methods.filter { $0 == "thread/resume" }.count, 1)
        runtime.detach(token)
        let reads = transport.methods.count
        stamp.addTimeInterval(6)
        runtime.drainForTesting()
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(transport.methods.count, reads)
    }

    func testStatusReconciliationDoesNotLoadAStandaloneConversation() async throws {
        let runtime = CodexRuntime(indexURL: index)
        let transport = StatusTransport()
        transport.status = ["type": "notLoaded"]
        let dialogs = CodexNativeDialogs(rpc: CodexRPC(transport: transport))
        runtime.nativeDialogs = dialogs
        let token = runtime.attach(AgentBinding(conversationID: UUID(), transcriptURL: nil), for: UUID()) { _ in }
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(transport.methods, ["thread/read"], "observing an old TUI must not acquire its writer lock")
        runtime.detach(token)
    }

    func testUnloadedDaemonThreadReturnsAuthorityToLiveRollout() async throws {
        let runtime = CodexRuntime(indexURL: index)
        let transport = StatusTransport()
        transport.status = ["type": "idle"]
        let dialogs = CodexNativeDialogs(rpc: CodexRPC(transport: transport))
        dialogs.onChange = { [weak runtime] in runtime?.receiveNativeStatus(thread: $0, activity: $1) }
        var stamp = Date()
        runtime.now = { stamp }
        runtime.nativeDialogs = dialogs
        let url = try rollout(named: "unloaded.jsonl")
        var seen: [AgentEvent] = []
        let token = runtime.attach(AgentBinding(conversationID: UUID(), transcriptURL: url), for: UUID()) { seen.append($0) }
        runtime.drainForTesting()
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(seen.last, .activity(.idle))
        try append(turn, to: url)
        runtime.drainForTesting()
        transport.status = ["type": "notLoaded"]
        stamp.addTimeInterval(6)
        runtime.drainForTesting()
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(seen.last, .activity(.busy), "the standalone turn must no longer be hidden by stale native idle")
        runtime.detach(token)
    }

    func testApprovalDialogOverridesWorkingAndRestoresTurnState() throws {
        let runtime = CodexRuntime(indexURL: index)
        let tab = UUID(), id = UUID()
        let url = try rollout(named: "approval.jsonl")
        var viewport: String? = "Working"
        runtime.readViewport = { requested in requested == tab ? viewport : nil }
        var seen: [AgentEvent] = []
        let token = runtime.attach(AgentBinding(conversationID: id, transcriptURL: url), for: tab) { seen.append($0) }
        runtime.drainForTesting()
        try append(turn, to: url)
        runtime.drainForTesting()
        XCTAssertEqual(seen.last, .activity(.busy))
        viewport = "Would you like to run the following command?\n› 1. Yes, proceed (y)\n  2. No (esc)\n\nPress enter to confirm or esc to cancel"
        runtime.drainForTesting()
        XCTAssertEqual(seen.last, .activity(.waiting))
        let count = seen.count
        runtime.drainForTesting()
        XCTAssertEqual(seen.count, count, "a standing prompt is one transition")
        viewport = nil
        runtime.drainForTesting()
        XCTAssertEqual(seen.last, .activity(.waiting), "an unreadable surface cannot prove dismissal")
        viewport = "Working"
        runtime.drainForTesting()
        XCTAssertEqual(seen.last, .activity(.busy))
        runtime.detach(token)
        viewport = "› 1. Yes\n  2. No\n\nPress enter to confirm or esc to cancel"
        let detachedCount = seen.count
        runtime.drainForTesting()
        XCTAssertEqual(seen.count, detachedCount)
    }

    func testSharedClockObservesCapturedApprovalAndStopsAfterDetach() throws {
        let clock = WatchClock(appIsActive: { false })
        let runtime = CodexRuntime(clock: clock, indexURL: index)
        let tab = UUID()
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Codex/approval-command.captured.txt")
        var viewport = try String(contentsOf: fixture, encoding: .utf8)
        var reads = 0
        runtime.readViewport = { requested in
            XCTAssertEqual(requested, tab)
            reads += 1
            return viewport
        }
        var seen: [AgentEvent] = []
        let token = runtime.attach(AgentBinding(conversationID: UUID(), transcriptURL: nil), for: tab) { seen.append($0) }
        clock.fire()
        XCTAssertEqual(seen.last, .activity(.waiting))
        viewport = "› Write a numbered list\n  1. One\n  2. Two"
        clock.fire()
        XCTAssertEqual(seen.last, .activity(.idle), "ordinary numbered output is not an approval dialog")
        runtime.detach(token)
        let detachedReads = reads
        clock.fire()
        XCTAssertEqual(reads, detachedReads)
    }

    func testTurnsAndRenamesBothReachTheAttachedTab() throws {
        let id = UUID()
        let url = try rollout(named: "a.jsonl")
        let runtime = CodexRuntime(indexURL: index)

        var seen: [AgentEvent] = []
        _ = runtime.attach(AgentBinding(conversationID: id, transcriptURL: url), for: UUID()) { seen.append($0) }
        runtime.drainForTesting() // prime both watchers

        try append(turn, to: url)
        try append(indexLine(id, "renamed"), to: index)
        runtime.drainForTesting()

        XCTAssertEqual(seen, [.lifecycle(.live), .activity(.busy), .title("renamed")])
    }

    func testEachTabOnlySeesItsOwnThread() throws {
        let mine = UUID(), theirs = UUID()
        let mineURL = try rollout(named: "mine.jsonl")
        let theirsURL = try rollout(named: "theirs.jsonl")
        let runtime = CodexRuntime(indexURL: index)

        var mineSeen: [AgentEvent] = [], theirsSeen: [AgentEvent] = []
        _ = runtime.attach(AgentBinding(conversationID: mine, transcriptURL: mineURL), for: UUID()) { mineSeen.append($0) }
        _ = runtime.attach(AgentBinding(conversationID: theirs, transcriptURL: theirsURL), for: UUID()) { theirsSeen.append($0) }
        runtime.drainForTesting()

        try append(turn, to: mineURL)
        try append(indexLine(theirs, "theirs renamed"), to: index)
        runtime.drainForTesting()

        XCTAssertEqual(mineSeen, [.lifecycle(.live), .activity(.busy)])
        XCTAssertEqual(theirsSeen, [.title("theirs renamed")])
    }

    func testDetachingStopsEverythingForThatTab() throws {
        let id = UUID()
        let url = try rollout(named: "a.jsonl")
        let runtime = CodexRuntime(indexURL: index)

        var seen: [AgentEvent] = []
        let binding = AgentBinding(conversationID: id, transcriptURL: url)
        let token = runtime.attach(binding, for: UUID()) { seen.append($0) }
        runtime.drainForTesting()
        runtime.detach(token)

        try append(turn, to: url)
        try append(indexLine(id, "after detach"), to: index)
        runtime.drainForTesting()

        XCTAssertEqual(seen, [], "a closed tab must not be written to")
    }

    /// A restored tab whose thread was renamed while the app was closed is NOT this watcher's
    /// job — `rebind`'s `thread/read` settles that. Tailing from the end is what keeps a
    /// reopened app from replaying every rename in the user's history across every tab.
    func testAttachingDoesNotReplayRenamesThatPredateIt() throws {
        let id = UUID()
        let url = try rollout(named: "a.jsonl")
        try append(indexLine(id, "renamed while we were closed"), to: index)

        var seen: [AgentEvent] = []
        let runtime = CodexRuntime(indexURL: index)
        _ = runtime.attach(AgentBinding(conversationID: id, transcriptURL: url), for: UUID()) { seen.append($0) }
        runtime.drainForTesting()

        XCTAssertEqual(seen, [])
    }

    func testATabWithNoTranscriptStillGetsRenames() throws {
        let id = UUID()
        let runtime = CodexRuntime(indexURL: index)

        var seen: [AgentEvent] = []
        _ = runtime.attach(AgentBinding(conversationID: id, transcriptURL: nil), for: UUID()) { seen.append($0) }
        runtime.drainForTesting()

        try append(indexLine(id, "still named"), to: index)
        runtime.drainForTesting()

        XCTAssertEqual(seen, [.title("still named")])
    }

    func testTwoTabsOnOneThreadBothReceiveNameEvents() throws {
        let id = UUID()
        let runtime = CodexRuntime(indexURL: index)

        var first: [AgentEvent] = []
        var second: [AgentEvent] = []
        let binding = AgentBinding(conversationID: id, transcriptURL: nil)
        _ = runtime.attach(binding, for: UUID()) { first.append($0) }
        _ = runtime.attach(binding, for: UUID()) { second.append($0) }
        runtime.drainForTesting() // prime

        try append(indexLine(id, "renamed"), to: index)
        runtime.drainForTesting()

        XCTAssertEqual(first, [.title("renamed")], "the second attach must not replace the first's registration")
        XCTAssertEqual(second, [.title("renamed")])
    }

    func testDetachingOneOfTwoLeavesTheOtherWatching() throws {
        let id = UUID()
        let runtime = CodexRuntime(indexURL: index)

        var first: [AgentEvent] = []
        var second: [AgentEvent] = []
        let binding = AgentBinding(conversationID: id, transcriptURL: nil)
        let a = runtime.attach(binding, for: UUID()) { first.append($0) }
        _ = runtime.attach(binding, for: UUID()) { second.append($0) }
        runtime.drainForTesting() // prime

        runtime.detach(a)
        try append(indexLine(id, "after"), to: index)
        runtime.drainForTesting()

        XCTAssertTrue(first.isEmpty, "a detached subscriber must receive nothing")
        XCTAssertEqual(second, [.title("after")], "the surviving subscriber must keep its watcher")
    }

    func testDetachingTheLastSubscriberUnregistersTheThread() throws {
        let id = UUID()
        let runtime = CodexRuntime(indexURL: index)
        var seen: [AgentEvent] = []
        let binding = AgentBinding(conversationID: id, transcriptURL: nil)
        let a = runtime.attach(binding, for: UUID()) { seen.append($0) }
        let b = runtime.attach(binding, for: UUID()) { seen.append($0) }
        runtime.drainForTesting() // prime

        runtime.detach(a)
        runtime.detach(b)

        try append(indexLine(id, "late"), to: index)
        runtime.drainForTesting()

        XCTAssertTrue(seen.isEmpty, "no subscriber remains, so nothing may be delivered")
    }

    /// `offset: nil`, always. This watcher starts at end-of-file, so recording its read
    /// position as indexing progress would make the backfill resume from there and silently
    /// never index that thread's history — exactly the history ⌘K exists to search. Proved
    /// end to end, through the real `onMessages` wiring in `attach`, against a real
    /// `SQLiteSearchIndex` — a fake would only prove the wiring calls `ingest`, not that the
    /// argument it calls it with is the one that keeps the backfill's resume point alone.
    func testLiveIngestNeverRecordsAReadPosition() throws {
        let id = UUID()
        let url = try rollout(named: "a.jsonl")
        let searchIndex = try SQLiteSearchIndex(at: dir.appendingPathComponent("search.sqlite"))
        let runtime = CodexRuntime(
            indexURL: index,
            searchIndex: { searchIndex },
            projectPath: { _ in "/w/fd" },
            workingDirectory: { _ in "/w/fd" }
        )

        _ = runtime.attach(AgentBinding(conversationID: id, transcriptURL: url), for: UUID()) { _ in }
        runtime.drainForTesting() // establishes the start position on the empty file

        let prose = #"{"type":"event_msg","payload":{"type":"user_message","message":"the rename bug"}}"# + "\n"
        try append(prose, to: url)
        runtime.drainForTesting()

        let hits = try searchIndex.search("rename", projects: ["/w/fd"], limit: 10)
        XCTAssertEqual(hits.count, 1)
        // Not just a count: `readOffset == 0` alone cannot tell a source row that landed
        // through this wiring apart from one that was never written at all (an absent row
        // reports 0 too), so asserting the agent is what actually proves the real `ingest`
        // call ran, rather than proving only that the file was polled.
        XCTAssertEqual(hits[0].agent, "codex")
        XCTAssertEqual(
            searchIndex.readOffset(for: url), 0,
            "a live ingest must never advance the backfill's resume point for this file"
        )
    }
}
