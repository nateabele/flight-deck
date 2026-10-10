import XCTest
import IntakeKit
@testable import FlightDeck

/// `AgentConversationTransfer`: each agent's conversation lands in the second account's home at
/// the path that agent's resume looks in, so a rolled-over tab resumes the same conversation
/// rather than starting a fresh one under the same id. Synthetic files only; the layouts are
/// the ones the live probes established (see the type's doc comment).
@MainActor
final class ConversationTransferTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("fd-transfer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func home(_ name: String) -> URL { root.appendingPathComponent(name, isDirectory: true) }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func read(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }

    // MARK: claude

    func testClaudeCarriesTheTranscriptAndItsSidecarIntoTheSameProjectDirectory() async throws {
        let id = UUID()
        let session = Session(title: "t", workingDirectory: "/work/app", pinnedConversationID: id)
        let a = home("a"), b = home("b")
        let source = ClaudeSession.transcriptURL(sessionID: id, workingDirectory: "/work/app",
                                                 projectsRoot: a.appendingPathComponent("projects"))
        try write("{\"turn\":1}\n", to: source)
        let sidecar = source.deletingLastPathComponent().appendingPathComponent(id.uuidString.lowercased())
        try write("sub", to: sidecar.appendingPathComponent("subagents/agent-1.jsonl"))

        let moved = try await ClaudeConversationTransfer().transfer(session, from: a, to: b)

        let target = ClaudeSession.transcriptURL(sessionID: id, workingDirectory: "/work/app",
                                                 projectsRoot: b.appendingPathComponent("projects"))
        XCTAssertEqual(read(target), "{\"turn\":1}\n", "claude --resume looks exactly here under the new home")
        XCTAssertEqual(read(target.deletingLastPathComponent()
            .appendingPathComponent("\(id.uuidString.lowercased())/subagents/agent-1.jsonl")), "sub")
        XCTAssertEqual(read(source), "{\"turn\":1}\n", "copied, never moved")
        XCTAssertEqual(moved, session)
    }

    /// A conversation resumed from another directory keeps the project directory it was born in.
    func testClaudeFindsATranscriptBornInAnotherDirectory() async throws {
        let id = UUID()
        let session = Session(title: "t", workingDirectory: "/work/app", pinnedConversationID: id)
        let a = home("a"), b = home("b")
        try write("x", to: a.appendingPathComponent("projects/-elsewhere/\(id.uuidString.lowercased()).jsonl"))
        _ = try await ClaudeConversationTransfer().transfer(session, from: a, to: b)
        XCTAssertEqual(read(b.appendingPathComponent("projects/-elsewhere/\(id.uuidString.lowercased()).jsonl")), "x")
    }

    func testClaudeWithNothingWrittenCarriesNothing() async throws {
        let session = Session(title: "t", workingDirectory: "/work/app")
        let moved = try await ClaudeConversationTransfer().transfer(session, from: home("a"), to: home("b"))
        XCTAssertEqual(moved, session)
        XCTAssertFalse(FileManager.default.fileExists(atPath: home("b").path))
    }

    // MARK: codex

    func testCodexCarriesTheRolloutAndItsNameAndRepointsTheTab() async throws {
        let id = UUID()
        let lower = id.uuidString.lowercased()
        let a = home("a"), b = home("b")
        let rollout = a.appendingPathComponent("sessions/2026/10/09/rollout-2026-10-09T11-09-14-\(lower).jsonl")
        try write("{\"type\":\"session_meta\"}\n", to: rollout)
        try write("{\"id\":\"other\",\"thread_name\":\"x\"}\n{\"id\":\"\(lower)\",\"thread_name\":\"fix it\"}\n",
                  to: a.appendingPathComponent("session_index.jsonl"))
        var session = Session(title: "t", workingDirectory: "/w", pinnedConversationID: id, agent: .codex)
        session.transcriptPath = rollout.path

        let moved = try await CodexConversationTransfer().transfer(session, from: a, to: b)

        let target = b.appendingPathComponent("sessions/2026/10/09/rollout-2026-10-09T11-09-14-\(lower).jsonl")
        XCTAssertEqual(read(target), "{\"type\":\"session_meta\"}\n")
        XCTAssertEqual(moved.transcriptPath, target.path, "the rollout watcher must tail the copy codex now appends to")
        XCTAssertEqual(read(b.appendingPathComponent("session_index.jsonl")),
                       "{\"id\":\"\(lower)\",\"thread_name\":\"fix it\"}\n", "only this thread's name travels")

        _ = try await CodexConversationTransfer().transfer(session, from: a, to: b)
        XCTAssertEqual(read(b.appendingPathComponent("session_index.jsonl"))?.components(separatedBy: "\n").count, 2,
                       "a second carry does not duplicate the name")
    }

    // MARK: grok

    func testGrokCarriesTheSessionDirectoryWithoutItsLocks() async throws {
        let id = UUID()
        let lower = id.uuidString.lowercased()
        let a = home("a"), b = home("b")
        let dir = a.appendingPathComponent("sessions/%2Fwork%2Fapp/\(lower)")
        try write("ctx", to: dir.appendingPathComponent("chat_history.jsonl"))
        try write("u", to: dir.appendingPathComponent("updates.jsonl"))
        try write("", to: dir.appendingPathComponent("updates.jsonl.lock"))
        let session = Session(title: "t", workingDirectory: "/work/app", pinnedConversationID: id, agent: .grok)

        _ = try await GrokConversationTransfer().transfer(session, from: a, to: b)

        let target = b.appendingPathComponent("sessions/%2Fwork%2Fapp/\(lower)")
        XCTAssertEqual(read(target.appendingPathComponent("chat_history.jsonl")), "ctx", "the model's context")
        XCTAssertEqual(GrokSessionFiles.transcriptURL(home: b, workingDirectory: "/work/app", conversationID: id),
                       target.appendingPathComponent("updates.jsonl"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.appendingPathComponent("updates.jsonl.lock").path))
    }

    // MARK: OpenCode

    func testOpenCodeExportsFromTheOldRootAndImportsIntoTheNewOne() async throws {
        let a = home("a"), b = home("b")
        let mirror = home("mirror")
        let oldDatabase = a.appendingPathComponent("opencode/opencode.db")
        try write("", to: oldDatabase)
        var session = Session(title: "t", workingDirectory: "/work/app", agent: .opencode)
        session.transcriptPath = OpenCodeMirror.url(forSession: "ses_abc123", database: oldDatabase, root: mirror).path

        var calls: [(args: [String], home: URL, dir: URL)] = []
        let transfer = OpenCodeConversationTransfer(run: { args, dataHome, dir in
            calls.append((args, dataHome, dir))
            if args.first == "import" {
                // What a real import leaves behind: the new root's database.
                try "".write(to: b.appendingPathComponent("opencode/opencode.db"), atomically: true, encoding: .utf8)
                return Data()
            }
            return Data("{\"info\":{}}".utf8)
        }, mirrorRoot: mirror)
        try FileManager.default.createDirectory(at: b.appendingPathComponent("opencode"), withIntermediateDirectories: true)

        let moved = try await transfer.transfer(session, from: a, to: b)

        XCTAssertEqual(calls.map(\.args.first), ["export", "import"])
        XCTAssertEqual(calls[0].args, ["export", "ses_abc123"])
        XCTAssertEqual(calls[0].home, a)
        XCTAssertEqual(calls[1].home, b)
        XCTAssertEqual(calls[1].dir.path, "/work/app", "import stamps the session with its working directory")
        XCTAssertEqual(moved.transcriptPath,
                       OpenCodeMirror.url(forSession: "ses_abc123",
                                          database: b.appendingPathComponent("opencode/opencode.db"), root: mirror).path)
    }

    func testOpenCodeWithNoSessionInItsPathRefuses() async {
        let session = Session(title: "t", workingDirectory: "/w", agent: .opencode)
        do {
            _ = try await OpenCodeConversationTransfer(run: { _, _, _ in Data() }).transfer(session, from: home("a"), to: home("b"))
            XCTFail("expected a refusal")
        } catch {
            XCTAssertEqual(error as? ConversationTransferError, .unknownSession)
        }
    }

    // MARK: the capability

    /// gemini is single-account (agy signs in through the keyring), so it has nowhere to carry a
    /// conversation to; every multi-account agent states a transfer.
    func testEveryMultiAccountAgentCanCarryAConversation() {
        for agent in AgentID.allCases {
            XCTAssertEqual(agent.conversationTransfer == nil, agent.homeEnvironmentKey == nil, "\(agent)")
        }
    }
}
