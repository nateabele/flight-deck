import XCTest
import FleetKit
import IntakeKit
@testable import FlightDeck

/// ⌘K hears a gemini (agy) or grok tab's new messages while it runs, not only at the next
/// backfill — the same promise `CodexRuntimeAttachmentTests.testLiveIngestNeverRecordsAReadPosition`
/// pins for codex. Every line here is synthetic.
@MainActor
final class LiveSearchIndexingTests: XCTestCase {
    private var dir: URL!
    private var index: SQLiteSearchIndex!
    private let project = "/w/fd"

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("live-index-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        index = try SQLiteSearchIndex(at: dir.appendingPathComponent("search.sqlite"))
    }

    override func tearDownWithError() throws {
        index = nil
        try? FileManager.default.removeItem(at: dir)
    }

    private func append(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    private func hits(_ word: String) throws -> [TranscriptHit] {
        try index.search(word, projects: [project], limit: 10)
    }

    // MARK: gemini

    private var geminiPaths: GeminiPaths { GeminiPaths(root: dir.appendingPathComponent("agy", isDirectory: true)) }

    private func userLine(_ step: Int, _ text: String) -> String {
        let content = "<USER_REQUEST>\n\(text)\n</USER_REQUEST>\n<ADDITIONAL_METADATA>\nThe current local time is: noon\n</ADDITIONAL_METADATA>"
        let record: [String: Any] = ["step_index": step, "source": "USER_EXPLICIT", "type": "USER_INPUT",
                                     "status": "DONE", "created_at": "2026-10-09T12:00:0\(step)Z", "content": content]
        return String(decoding: try! JSONSerialization.data(withJSONObject: record), as: UTF8.self) + "\n"
    }

    private func modelLine(_ step: Int, _ text: String, type: String = "PLANNER_RESPONSE") -> String {
        let record: [String: Any] = ["step_index": step, "source": "MODEL", "type": type,
                                     "status": "DONE", "created_at": "2026-10-09T12:00:0\(step)Z", "content": text]
        return String(decoding: try! JSONSerialization.data(withJSONObject: record), as: UTF8.self) + "\n"
    }

    private func geminiRuntime(held: @escaping () -> UUID?) -> GeminiRuntime {
        let observer = GeminiObserver(held: { _ in held() }, running: { _ in false },
                                      pending: { _ in nil }, title: { _ in nil })
        let index = self.index!
        let project = self.project
        return GeminiRuntime(clock: nil, paths: geminiPaths, roots: { _ in [1] }, observer: observer,
                             searchIndex: { index }, projectPath: { _ in project },
                             workingDirectory: { _ in project })
    }

    /// agy writes the first request the moment it is submitted (~30 ms, probed live on agy 1.3.1,
    /// 2026-10-09), which is also the moment the tab learns its conversation id — so by the time a
    /// `.rebound` re-attach first looks, that line is already on disk. A tail that skipped the
    /// existing file the way claude's does would lose exactly the first thing the user typed.
    func testGeminiIndexesWhatTheTranscriptAlreadyHeldAtAttach() throws {
        let id = UUID()
        try append(userLine(0, "find the zebra bug"), to: geminiPaths.transcript(id))
        let rt = geminiRuntime { id }
        _ = rt.attach(AgentBinding(conversationID: id, transcriptURL: geminiPaths.transcript(id)), for: UUID()) { _ in }
        rt.drain()

        let found = try hits("zebra")
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.agent, "gemini")
        XCTAssertEqual(found.first?.conversationID, GeminiPaths.name(id))
        XCTAssertEqual(try hits("noon").count, 0, "the request is unwrapped from agy's injected metadata")
        XCTAssertEqual(index.readOffset(for: geminiPaths.transcript(id)), 0,
                       "a live ingest must never advance the backfill's resume point")
    }

    func testGeminiIndexesAReplyAppendedWhileTheTabRuns() throws {
        let id = UUID()
        let url = geminiPaths.transcript(id)
        let rt = geminiRuntime { id }
        _ = rt.attach(AgentBinding(conversationID: id, transcriptURL: url), for: UUID()) { _ in }
        rt.drain()

        try append(userLine(0, "hello"), to: url)
        try append(modelLine(1, "the giraffe answer"), to: url)
        try append(modelLine(2, "tool output okapi", type: "GENERIC"), to: url)
        rt.drain()
        XCTAssertEqual(try hits("giraffe").count, 1)
        XCTAssertEqual(try hits("okapi").count, 0, "tool results stay out, as in the backfill")

        rt.drain()
        XCTAssertEqual(try hits("giraffe").count, 1, "a second pass adds nothing")
    }

    /// The tab is pinned to a placeholder until agy names the conversation; the store answers
    /// `.rebound` by detaching and re-attaching on the new binding (`SessionStore.repinRebound`).
    /// The tail has to follow it there.
    func testGeminiFollowsTheConversationARebindNames() throws {
        let placeholder = UUID()
        let minted = UUID()
        let rt = geminiRuntime { minted }
        var token: AttachmentToken?
        let tab = UUID()
        var onEvent: ((AgentEvent) -> Void)!
        onEvent = { event in
            guard case .rebound(let binding) = event else { return }
            rt.detach(token!)
            token = rt.attach(binding, for: tab, onEvent: onEvent)
        }
        token = rt.attach(AgentBinding(conversationID: placeholder, transcriptURL: geminiPaths.transcript(placeholder)),
                          for: tab, onEvent: onEvent)
        try append(userLine(0, "the minted marmot"), to: geminiPaths.transcript(minted))
        rt.drain() // rebound
        rt.drain() // tails the minted conversation
        let found = try hits("marmot")
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.conversationID, GeminiPaths.name(minted))
    }

    /// The store's own closures, not a test's: a gemini runtime built by `SessionStore` reaches
    /// the index the app wires in, and files the message under the tab's project.
    func testTheStoresGeminiRuntimeIndexesLive() throws {
        let store = SessionStore(provider: nil, persistence: nil)
        store.geminiPaths = geminiPaths
        store.searchIndex = index
        let created = store.newSession(in: URL(fileURLWithPath: project, isDirectory: true), agent: .gemini)
        let id = try XCTUnwrap(store.pinnedConversationID(of: created.id))
        let rt = try XCTUnwrap(store.runtime(for: .gemini, account: nil) as? GeminiRuntime)
        _ = rt.attach(AgentBinding(conversationID: id, transcriptURL: geminiPaths.transcript(id)), for: created.id) { _ in }
        try append(userLine(0, "store wired wombat"), to: geminiPaths.transcript(id))
        rt.drain()
        XCTAssertEqual(try hits("wombat").count, 1)
    }

    // MARK: grok

    private func grokLine(_ kind: String, _ text: String, ms: Int) -> String {
        let record: [String: Any] = [
            "timestamp": ms / 1000, "method": "session/update",
            "params": ["sessionId": "s", "_meta": ["agentTimestampMs": ms],
                       "update": ["sessionUpdate": kind, "content": ["type": "text", "text": text]]],
        ]
        return String(decoding: try! JSONSerialization.data(withJSONObject: record), as: UTF8.self) + "\n"
    }

    private func grokTranscript(_ id: UUID) -> URL {
        dir.appendingPathComponent("grok/sessions/%2Fw%2Ffd", isDirectory: true)
            .appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
            .appendingPathComponent(GrokSessionFiles.transcriptName)
    }

    func testGrokIndexesPromptsAndRepliesWhileTheTabRuns() throws {
        let id = UUID()
        let url = grokTranscript(id)
        let index = self.index!
        let project = self.project
        let rt = GrokRuntime(clock: nil, searchIndex: { index }, projectPath: { _ in project },
                             workingDirectory: { _ in project })
        _ = rt.attach(AgentBinding(conversationID: id, transcriptURL: url), for: UUID()) { _ in }
        rt.drainForTesting()

        try append(grokLine("user_message_chunk", "where is the narwhal", ms: 1_000), to: url)
        try append(grokLine("agent_message_chunk", "the narwhal lives here", ms: 2_000), to: url)
        try append(grokLine("agent_thought_chunk", "secret pangolin", ms: 3_000), to: url)
        rt.drainForTesting()

        let found = try hits("narwhal")
        XCTAssertEqual(found.count, 2)
        XCTAssertEqual(Set(found.map(\.agent)), ["grok"])
        XCTAssertEqual(found.first?.conversationID, id.uuidString.lowercased())
        XCTAssertEqual(try hits("pangolin").count, 0, "reasoning stays out, as in the backfill")
        XCTAssertEqual(index.readOffset(for: url), 0)
    }

    func testTheStoresGrokRuntimeIndexesLive() throws {
        let store = SessionStore(provider: nil, persistence: nil)
        store.searchIndex = index
        let home = dir.appendingPathComponent("grok-home", isDirectory: true)
        store.overrideAdapter(GrokAdapter(home: { home }), for: .grok, account: nil)
        let created = store.newSession(in: URL(fileURLWithPath: project, isDirectory: true), agent: .grok)
        let rt = try XCTUnwrap(store.runtime(for: .grok, account: nil) as? GrokRuntime)
        // The store's own binding, so this attach and any the store already made tail one file.
        let session = try XCTUnwrap(store.repos.flatMap(\.sessions).first { $0.id == created.id })
        let binding = store.adapter(for: .grok, account: nil).binding(for: session)
        let id = binding.conversationID
        let url = try XCTUnwrap(binding.transcriptURL)
        _ = rt.attach(AgentBinding(conversationID: id, transcriptURL: url), for: created.id) { _ in }
        rt.drainForTesting()
        try append(grokLine("user_message_chunk", "store wired walrus", ms: 1_000), to: url)
        rt.drainForTesting()
        XCTAssertEqual(try hits("walrus").count, 1)
    }
}
