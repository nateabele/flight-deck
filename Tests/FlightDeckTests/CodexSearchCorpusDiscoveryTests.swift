import XCTest
@testable import FlightDeck

final class CodexSearchCorpusDiscoveryTests: XCTestCase {
    private let corpus = CodexSearchCorpus()

    private var roots: [URL] = []

    override func tearDown() {
        for root in roots { try? FileManager.default.removeItem(at: root) }
        roots = []
        super.tearDown()
    }

    /// A fresh temp directory this test owns, cleaned up in `tearDown` even on failure.
    private func makeRoot() -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-corpus-tests-\(UUID().uuidString)", isDirectory: true)
        roots.append(root)
        return root
    }

    /// Writes a one-line `session_meta` rollout, matching the shape codex-cli 0.154.0 actually
    /// writes: `cwd` alongside `session_id`, ahead of where the real `base_instructions` blob
    /// would sit.
    private func writeRollout(
        at url: URL, id: String, cwd: String, source: String? = "exec"
    ) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        var payload: [String: Any] = ["session_id": id, "cwd": cwd]
        if let source { payload["source"] = source }
        let record: [String: Any] = [
            "timestamp": "2026-09-16T00:00:00Z", "type": "session_meta", "payload": payload,
        ]
        let line = String(data: try JSONSerialization.data(withJSONObject: record), encoding: .utf8)!
        try (line + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private func rolloutURL(under home: URL, name: String) -> URL {
        home.appendingPathComponent("sessions/2026/09/16/\(name)", isDirectory: false)
    }

    /// The one case that has to work at all: a rollout whose recorded cwd is exactly the
    /// project's own path.
    func testAttributesARolloutByItsRecordedCwd() throws {
        let root = makeRoot()
        let home = root.appendingPathComponent(".codex", isDirectory: true)
        let project = root.appendingPathComponent("proj", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)

        let url = rolloutURL(under: home, name: "rollout-a.jsonl")
        try writeRollout(at: url, id: "conv-a", cwd: project.path)

        let refs = corpus.transcripts(
            forProjects: [project.path],
            accounts: [AgentAccount(agent: .codex, displayName: "Default", home: home)]
        )

        let ref = try XCTUnwrap(refs.first)
        XCTAssertEqual(refs.count, 1)
        XCTAssertEqual(ref.url, url)
        XCTAssertEqual(ref.conversationID, "conv-a")
        XCTAssertEqual(ref.projectPath, project.path)
        XCTAssertEqual(ref.workingDirectory, project.path)
        XCTAssertEqual(ref.accountHome, home)
        XCTAssertEqual(ref.agent, .codex)
    }

    /// A scratchpad or an unopened repo has a real cwd, just not one any sidebar project owns
    /// — the walk must not attribute it to whatever project happens to be open.
    func testSkipsARolloutWhoseCwdIsNoSidebarProject() throws {
        let root = makeRoot()
        let home = root.appendingPathComponent(".codex", isDirectory: true)
        let project = root.appendingPathComponent("proj", isDirectory: true)
        let scratch = root.appendingPathComponent("scratch", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)

        try writeRollout(
            at: rolloutURL(under: home, name: "rollout-b.jsonl"), id: "conv-b", cwd: scratch.path
        )

        let refs = corpus.transcripts(
            forProjects: [project.path],
            accounts: [AgentAccount(agent: .codex, displayName: "Default", home: home)]
        )

        XCTAssertEqual(refs, [])
    }

    /// `candidateWorkingDirectories` is what makes a worktree rollout findable at all —
    /// discovery must attribute it to the parent project while still carrying the worktree
    /// path as its own `workingDirectory`, the same split `ClaudeSearchCorpus` makes.
    func testAttributesAWorktreeRolloutToItsParentProject() throws {
        let root = makeRoot()
        let home = root.appendingPathComponent(".codex", isDirectory: true)
        let project = root.appendingPathComponent("proj", isDirectory: true)
        let worktree = project.appendingPathComponent(".claude/worktrees/wt1", isDirectory: true)
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)

        try writeRollout(
            at: rolloutURL(under: home, name: "rollout-c.jsonl"), id: "conv-c", cwd: worktree.path
        )

        let refs = corpus.transcripts(
            forProjects: [project.path],
            accounts: [AgentAccount(agent: .codex, displayName: "Default", home: home)]
        )

        let ref = try XCTUnwrap(refs.first)
        XCTAssertEqual(ref.projectPath, project.path)
        XCTAssertEqual(ref.workingDirectory, worktree.path)
    }

    /// `archived_sessions/` sits beside `sessions/`, not under it — a rollout there must never
    /// surface even when its cwd would otherwise match, because this walk never descends into it.
    func testSkipsArchivedSessions() throws {
        let root = makeRoot()
        let home = root.appendingPathComponent(".codex", isDirectory: true)
        let project = root.appendingPathComponent("proj", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent("sessions", isDirectory: true),
            withIntermediateDirectories: true
        )

        let archived = home.appendingPathComponent(
            "archived_sessions/2026/09/16", isDirectory: true
        )
        try FileManager.default.createDirectory(at: archived, withIntermediateDirectories: true)
        try writeRollout(
            at: archived.appendingPathComponent("rollout-archived.jsonl"),
            id: "conv-archived", cwd: project.path
        )

        let refs = corpus.transcripts(
            forProjects: [project.path],
            accounts: [AgentAccount(agent: .codex, displayName: "Default", home: home)]
        )

        XCTAssertEqual(refs, [])
    }

    /// `source` drives the `.automated` ranking tier downstream — it has to survive discovery
    /// as the literal string codex wrote, not be dropped or normalised.
    func testCarriesSourceAsProvenance() throws {
        let root = makeRoot()
        let home = root.appendingPathComponent(".codex", isDirectory: true)
        let project = root.appendingPathComponent("proj", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)

        try writeRollout(
            at: rolloutURL(under: home, name: "rollout-d.jsonl"), id: "conv-d",
            cwd: project.path, source: "exec"
        )

        let refs = corpus.transcripts(
            forProjects: [project.path],
            accounts: [AgentAccount(agent: .codex, displayName: "Default", home: home)]
        )

        XCTAssertEqual(try XCTUnwrap(refs.first).provenance, "exec")
    }

    /// macOS routinely reports a cwd as `/private/var/...` where the sidebar's own path says
    /// `/var/...` (or the reverse) — an exact-string comparison here is the failure
    /// `CodexAdapter.threads(inDirectory:)` names as silent and indistinguishable from "no
    /// threads at all". Both `project` and the fixture directory the rollout's cwd points at
    /// are real, existing directories, so `resolvingSymlinksInPath` actually has something to
    /// fold rather than passing an already-standardised string straight through.
    func testNormalisesPrivateVarAgainstVar() throws {
        let root = makeRoot()
        let home = root.appendingPathComponent(".codex", isDirectory: true)
        let project = root.appendingPathComponent("proj", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)

        // Skip rather than fail on a host whose `TMPDIR` is not under `/var` — the test's
        // intent is "private/var normalises against var", not "this machine's temp root is
        // where macOS puts it", and asserting the latter would hard-fail the suite on a host
        // this test was never meant to constrain.
        try XCTSkipUnless(project.path.hasPrefix("/var/"), "fixture does not sit under /var")
        let viaPrivate = "/private" + project.path

        try writeRollout(
            at: rolloutURL(under: home, name: "rollout-e.jsonl"), id: "conv-e", cwd: viaPrivate
        )

        let refs = corpus.transcripts(
            forProjects: [project.path],
            accounts: [AgentAccount(agent: .codex, displayName: "Default", home: home)]
        )

        let ref = try XCTUnwrap(refs.first)
        XCTAssertEqual(ref.projectPath, project.path)
        // The literal recorded cwd is preserved even though it differs from the project path
        // that won the match — that difference is the whole point of the field.
        XCTAssertEqual(ref.workingDirectory, viaPrivate)
    }

    /// 6 of 563 real rollouts on the measured machine had an unparsable first line. One bad
    /// file must drop only itself, not the sibling rollouts it happens to share a directory with.
    func testAMalformedFirstLineDropsOnlyItsOwnFile() throws {
        let root = makeRoot()
        let home = root.appendingPathComponent(".codex", isDirectory: true)
        let project = root.appendingPathComponent("proj", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)

        let goodURL = rolloutURL(under: home, name: "rollout-good.jsonl")
        try writeRollout(at: goodURL, id: "conv-good", cwd: project.path)

        let badURL = rolloutURL(under: home, name: "rollout-bad.jsonl")
        try FileManager.default.createDirectory(
            at: badURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try "not json at all\n".write(to: badURL, atomically: true, encoding: .utf8)

        let refs = corpus.transcripts(
            forProjects: [project.path],
            accounts: [AgentAccount(agent: .codex, displayName: "Default", home: home)]
        )

        XCTAssertEqual(refs.map(\.conversationID), ["conv-good"])
    }

    /// `session_index.jsonl` is the only place a codex rename is observable; read once per
    /// account and stamped onto every rollout it names, leaving the (common) unlisted case nil.
    func testReadsTheIndexedNameFromSessionIndex() throws {
        let root = makeRoot()
        let home = root.appendingPathComponent(".codex", isDirectory: true)
        let project = root.appendingPathComponent("proj", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)

        try writeRollout(
            at: rolloutURL(under: home, name: "rollout-named.jsonl"),
            id: "conv-named", cwd: project.path
        )
        try writeRollout(
            at: rolloutURL(under: home, name: "rollout-unnamed.jsonl"),
            id: "conv-unnamed", cwd: project.path
        )

        let indexLine = #"{"id":"conv-named","thread_name":"Fix the sidebar","updated_at":"2026-09-16T00:00:00Z"}"#
        try (indexLine + "\n").write(
            to: home.appendingPathComponent("session_index.jsonl"), atomically: true, encoding: .utf8
        )

        let refs = corpus.transcripts(
            forProjects: [project.path],
            accounts: [AgentAccount(agent: .codex, displayName: "Default", home: home)]
        )

        let named = try XCTUnwrap(refs.first { $0.conversationID == "conv-named" })
        XCTAssertEqual(named.indexedName, "Fix the sidebar")

        let unnamed = try XCTUnwrap(refs.first { $0.conversationID == "conv-unnamed" })
        XCTAssertNil(unnamed.indexedName)
    }

    /// `CodexNameWatcher` reads the same file through `UUID(uuidString:)`, which is
    /// case-insensitive, so a live rename matches its listener regardless of which case codex
    /// wrote the hex in. The lookup here must agree, or two files disagreeing on hex case —
    /// codex is not documented to guarantee one — silently degrades naming to the
    /// first-user-message fallback everywhere.
    func testMatchesTheIndexedNameRegardlessOfHexCase() throws {
        let root = makeRoot()
        let home = root.appendingPathComponent(".codex", isDirectory: true)
        let project = root.appendingPathComponent("proj", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)

        let id = "5A1B2C3D-4E5F-6789-ABCD-EF0123456789"
        try writeRollout(
            at: rolloutURL(under: home, name: "rollout-named.jsonl"), id: id, cwd: project.path
        )

        let indexLine = #"{"id":"\#(id.lowercased())","thread_name":"Fix the sidebar","updated_at":"2026-09-16T00:00:00Z"}"#
        try (indexLine + "\n").write(
            to: home.appendingPathComponent("session_index.jsonl"), atomically: true, encoding: .utf8
        )

        let refs = corpus.transcripts(
            forProjects: [project.path],
            accounts: [AgentAccount(agent: .codex, displayName: "Default", home: home)]
        )

        let named = try XCTUnwrap(refs.first { $0.conversationID == id })
        XCTAssertEqual(named.indexedName, "Fix the sidebar")
    }
}
