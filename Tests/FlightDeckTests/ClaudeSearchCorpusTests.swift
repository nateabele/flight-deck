import XCTest
@testable import FlightDeck

final class ClaudeSearchCorpusTests: XCTestCase {
    private var corpus: AgentSearchCorpus { ClaudeAdapter.searchCorpus! }

    /// The walk knows which candidate directory produced the match, so a conversation that
    /// ran in a worktree resumes there. Before this the directory was thrown away and
    /// `SessionStore` re-derived it by probing.
    func testWorktreeTranscriptCarriesItsLiteralWorkingDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-corpus-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let accountHome = root.appendingPathComponent(".claude", isDirectory: true)
        let project = root.appendingPathComponent("proj", isDirectory: true).path
        let worktree = (project as NSString).appendingPathComponent(".claude/worktrees/wt1")

        // The worktree's own directory is what makes it discoverable at all — its presence
        // on disk IS the candidate list `candidateWorkingDirectories` walks.
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: worktree), withIntermediateDirectories: true
        )

        let projectsRoot = accountHome.appendingPathComponent("projects", isDirectory: true)
        let projectDir = projectsRoot.appendingPathComponent(
            ClaudeSession.encodedProjectDirName(for: project), isDirectory: true
        )
        let worktreeDir = projectsRoot.appendingPathComponent(
            ClaudeSession.encodedProjectDirName(for: worktree), isDirectory: true
        )
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: worktreeDir, withIntermediateDirectories: true)
        try "".write(
            to: projectDir.appendingPathComponent("main.jsonl"), atomically: true, encoding: .utf8
        )
        try "".write(
            to: worktreeDir.appendingPathComponent("wt.jsonl"), atomically: true, encoding: .utf8
        )

        let refs = corpus.transcripts(
            forProjects: [project],
            accounts: [AgentAccount(agent: .claude, displayName: "Default", home: accountHome)]
        )

        let worktreeRef = try XCTUnwrap(refs.first { $0.conversationID == "wt" })
        XCTAssertEqual(worktreeRef.workingDirectory, worktree)
        XCTAssertEqual(worktreeRef.projectPath, project)

        let mainRef = try XCTUnwrap(refs.first { $0.conversationID == "main" })
        XCTAssertEqual(mainRef.workingDirectory, project)
    }

    /// Claude's authority rule, unchanged in substance: a rename beats a first user message,
    /// and a pass that saw no rename may not overwrite one an earlier pass stored.
    func testRenameIsAuthoritativeAndAPlainMessageIsNot() {
        let ref = TranscriptRef(
            url: URL(fileURLWithPath: "/tmp/c.jsonl"), projectPath: "/w/fd",
            accountHome: URL(fileURLWithPath: "/home/.claude"), workingDirectory: "/w/fd",
            conversationID: "c", agent: .claude, provenance: nil, indexedName: nil,
            modified: Date(timeIntervalSince1970: 0)
        )
        let renamed = #"{"type":"custom-title","customTitle":"Badge anchor"}"#
        XCTAssertEqual(
            corpus.conversationName(inLines: [renamed], for: ref),
            .authoritative("Badge anchor")
        )

        let plain = #"{"type":"user","message":{"content":"fix the chevron"}}"#
        guard case .fallback = corpus.conversationName(inLines: [plain], for: ref) else {
            return XCTFail("a plain user message must not be authoritative")
        }

        XCTAssertEqual(corpus.conversationName(inLines: [], for: ref), .unknown)
    }
}
