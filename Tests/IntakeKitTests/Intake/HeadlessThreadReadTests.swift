import XCTest
import IntakeKit

/// `HeadlessAccess.threadRead` (R1): an ask-thread turn reads the repo and may run the
/// read-command allow-list, per adapter. Every case also pins that `.readOnly` builds exactly
/// what it built before, because threads add an access level beside it, never a change to it.
final class HeadlessThreadReadTests: XCTestCase {
    /// A home with no `.codex/config.toml`, so argv never depends on the operator's own config.
    static let noHome = URL(fileURLWithPath: "/nonexistent-fd-home")

    private func req(_ agent: AgentID, _ access: HeadlessAccess, model: String = "m",
                     resume: String? = nil) -> HeadlessRequest {
        HeadlessRequest(agent: agent, model: model, effort: "high", cwd: URL(fileURLWithPath: "/repo"),
                        readableDirs: [URL(fileURLWithPath: "/intake/threads/t/workspace")], prompt: "P",
                        schemaFile: URL(fileURLWithPath: "/intake/threads/t/run/schema.json"), schemaJSON: "{}",
                        resumeSessionID: resume, access: access)
    }

    private func argv(_ r: HeadlessRequest) throws -> [String] {
        try HeadlessCommand.build(r, home: Self.noHome).arguments
    }

    private func value(after flag: String, in args: [String]) -> String? {
        guard let i = args.firstIndex(of: flag), args.indices.contains(i + 1) else { return nil }
        return args[i + 1]
    }

    // MARK: claude

    /// Claude gets the read commands as `Bash(<cmd> *)` allow rules beside Read/Grep/Glob, and
    /// the write-shaped flags of those same commands as deny rules, which beat any allow.
    func testClaudeAllowsTheReadCommandsAndDeniesTheirWritingFlags() throws {
        let args = try argv(req(.claude, .threadRead))
        let allowed = try XCTUnwrap(value(after: "--allowedTools", in: args))
        for rule in ["Read", "Grep", "Glob", "Bash(rg *)", "Bash(git log *)", "Bash(git show *)", "Bash(git diff *)",
                     "Bash(git blame *)", "Bash(git grep *)", "Bash(ls *)", "Bash(cat *)", "Bash(head *)",
                     "Bash(wc *)", "Bash(find *)"] {
            XCTAssertTrue(allowed.contains(rule), "missing allow \(rule)")
        }
        XCTAssertFalse(allowed.contains("Edit") || allowed.contains("Write"), "a thread turn never writes")
        XCTAssertFalse(allowed.contains("Bash(br "), "the graph reaches a thread through the workspace, not br")
        let denied = try XCTUnwrap(value(after: "--disallowedTools", in: args))
        for rule in ["Bash(find *-delete*)", "Bash(find *-exec*)", "Bash(git diff *--output*)", "Bash(rg *--pre*)",
                     "Bash(cat *>*)", "Bash(br create *)"] {
            XCTAssertTrue(denied.contains(rule), "missing deny \(rule)")
        }
        XCTAssertEqual(value(after: "--tools", in: args), "Read Grep Glob Bash")
        XCTAssertEqual(value(after: "--permission-mode", in: args), "dontAsk")
        XCTAssertEqual(value(after: "--add-dir", in: args), "/intake/threads/t/workspace", "the workspace is readable")
        XCTAssertTrue(args.contains("--restricted") && args.contains("--strict-mcp-config"))
        XCTAssertEqual(value(after: "--json-schema", in: args), "{}")
    }

    func testClaudeThreadTurnResumesItsSession() throws {
        let args = try argv(req(.claude, .threadRead, resume: "sess-1"))
        XCTAssertEqual(value(after: "--resume", in: args), "sess-1")
    }

    /// The round seats' argv, pinned as literals rather than as the constants that build them:
    /// a change to a constant would move the argv and its check together, and this test exists
    /// to fail exactly then. Captured from the build before `threadRead` existed.
    func testReadOnlyAndWriteArgvArePinnedLiterally() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("fd-thread-pin-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        func pinned(_ agent: AgentID, _ access: HeadlessAccess) throws -> [String] {
            let cwd = URL(fileURLWithPath: access == .readOnly ? "/repo" : "/work")
            let r = HeadlessRequest(agent: agent, model: agent == .gemini ? "gemini-3-pro" : "m", effort: "high", cwd: cwd,
                                    readableDirs: [URL(fileURLWithPath: "/intake/threads/t/workspace")], prompt: "P",
                                    schemaFile: URL(fileURLWithPath: "/intake/threads/t/run/schema.json"), schemaJSON: "{}",
                                    resumeSessionID: nil, access: access)
            let c = try HeadlessCommand.build(r, home: tmp)
            var args = [c.executable] + c.arguments
            if let i = args.firstIndex(of: "--session-id") { args[i + 1] = "<minted>" }
            return args
        }
        let write = HeadlessAccess.writeInWork(URL(fileURLWithPath: "/work"))
        let codexHead = ["codex", "exec", "--json", "-m", "m", "-c", "model_reasoning_effort=high", "--ignore-user-config",
                         "--ignore-rules", "--disable", "hooks", "-c", "model_reasoning_summary=detailed"]
        let codexTail = ["--skip-git-repo-check", "--output-schema", "/intake/threads/t/run/schema.json", "P"]
        let claudeHead = ["claude", "-p", "P", "--model", "m", "--effort", "high", "--output-format", "stream-json",
                          "--verbose", "--json-schema", "{}"]
        let grokHead = ["grok", "-p", "P", "--json-schema", "{}", "-m", "m", "--reasoning-effort", "high"]
        let grokCommon = ["--output-format", "streaming-messages-json", "--disable-web-search", "--no-subagents", "--no-plan",
                          "--disallowed-tools", "Agent", "--permission-mode", "dontAsk"]
        let schemaLine = "P\n\nReply with ONLY one JSON object that validates against this JSON Schema — no prose, no code fence:\n{}"

        XCTAssertEqual(try pinned(.claude, .readOnly), claudeHead + [
            "--permission-mode", "dontAsk", "--tools", "Read Grep Glob Bash",
            "--allowedTools", "Read Grep Glob Bash(br list *) Bash(br show *) Bash(br graph *) Bash(br ready *)",
            "--disallowedTools", "Bash(br create *) Bash(br update *) Bash(br close *) Bash(br reopen *) Bash(br delete *) Bash(br dep *) Bash(br label *) Bash(br comments *) Bash(br sync *) Bash(br defer *) Bash(br undefer *) Bash(br q *) Bash(br init *)",
            "--add-dir", "/intake/threads/t/workspace", "--restricted", "--strict-mcp-config"])
        XCTAssertEqual(try pinned(.claude, write), claudeHead + [
            "--permission-mode", "acceptEdits", "--tools", "Read Edit Write", "--allowedTools", "Read Edit Write",
            "--disallowedTools", "Bash WebFetch WebSearch Task NotebookEdit", "--add-dir", "/work",
            "--restricted", "--strict-mcp-config"])
        XCTAssertEqual(try pinned(.codex, .readOnly), codexHead + ["-s", "read-only"] + codexTail)
        XCTAssertEqual(try pinned(.codex, write), codexHead + [
            "-s", "workspace-write", "-c", "sandbox_workspace_write.exclude_tmpdir_env_var=true",
            "-c", "sandbox_workspace_write.exclude_slash_tmp=true", "-c", "sandbox_workspace_write.writable_roots=[]"]
            + codexTail)
        XCTAssertEqual(try pinned(.gemini, .readOnly), [
            "agy", "-p", "P" + HeadlessCommand.geminiReadOnlyNote, "--output-format", "stream-json", "--json-schema", "{}",
            "--model", "gemini-3-pro", "--disable-slash-commands", "--project", "flight-deck-planning",
            "--add-dir", "/intake/threads/t/workspace"])
        XCTAssertTrue(HeadlessCommand.geminiReadOnlyNote.hasPrefix("\n\n(This run is read-only. Writing or editing files"))
        XCTAssertEqual(try pinned(.gemini, write), [
            "agy", "-p", "P", "--output-format", "stream-json", "--json-schema", "{}", "--model", "gemini-3-pro",
            "--disable-slash-commands", "--mode", "accept-edits", "--sandbox"])
        XCTAssertEqual(try pinned(.grok, .readOnly), grokHead + ["--cwd", "/repo"] + grokCommon + [
            "--tools", "read_file,grep,list_dir", "--deny", "Edit", "--deny", "Write", "--deny", "Bash", "--deny", "WebFetch",
            "--deny", "WebSearch", "--deny", "MCPTool", "--deny", "Read(**/.git/**)", "--deny", "Read(**/.beads/**)",
            "--session-id", "<minted>"])
        XCTAssertEqual(try pinned(.grok, write), grokHead + ["--cwd", "/work"] + grokCommon + [
            "--tools", "read_file,grep,list_dir,search_replace,write", "--allow", "Edit(/work/**)", "--deny", "Bash",
            "--deny", "WebFetch", "--deny", "WebSearch", "--deny", "MCPTool", "--deny", "Read(**/.git/**)",
            "--deny", "Read(**/.beads/**)", "--session-id", "<minted>"])
        XCTAssertEqual(try pinned(.opencode, .readOnly), [
            "opencode", "run", "--format", "json", "--agent", "flightdeck-readonly", "--dir", "/repo", "-m", "m",
            "--variant", "high", "--", schemaLine])
        XCTAssertEqual(try pinned(.opencode, write), [
            "opencode", "run", "--format", "json", "--agent", "flightdeck-integrator", "--dir", "/work", "-m", "m",
            "--variant", "high", "--", schemaLine])
    }

    /// The read-only and integrator OpenCode configs, byte for byte as before threads.
    func testOpenCodeRoundConfigsArePinnedLiterally() throws {
        func config(_ access: HeadlessAccess, cwd: String) throws -> String? {
            let r = HeadlessRequest(agent: .opencode, model: "m", effort: "high", cwd: URL(fileURLWithPath: cwd),
                                    readableDirs: [URL(fileURLWithPath: "/intake/threads/t/workspace")], prompt: "P",
                                    schemaFile: URL(fileURLWithPath: "/s.json"), schemaJSON: "{}", resumeSessionID: nil,
                                    access: access)
            return HeadlessCommand.environment(for: try HeadlessCommand.build(r, home: Self.noHome), base: [:],
                                               home: Self.noHome)["OPENCODE_CONFIG_CONTENT"]
        }
        let readOnlyAgent = #""flightdeck-readonly":{"description":"Flight Deck planning agent","mode":"primary","permission":{"*":"deny","glob":"allow","grep":"allow","list":"allow","read":"allow"}}"#
        XCTAssertEqual(try config(.readOnly, cwd: "/repo"),
                       #"{"agent":{"# + readOnlyAgent + #"},"autoupdate":false,"share":"disabled"}"#)
        XCTAssertEqual(try config(.writeInWork(URL(fileURLWithPath: "/work")), cwd: "/work"),
                       #"{"agent":{"flightdeck-integrator":{"description":"Flight Deck planning agent","mode":"primary","permission":{"*":"deny","edit":{"*":"deny","work\/*":"allow"},"glob":"allow","grep":"allow","list":"allow","read":"allow"}},"#
                       + readOnlyAgent + #"},"autoupdate":false,"share":"disabled"}"#)
    }

    // MARK: codex

    /// Codex keeps its `-s read-only` sandbox: its shell can run any reading command, and the
    /// sandbox is what refuses a write. The argv is exactly the read-only seat's.
    func testCodexKeepsItsReadOnlySandbox() throws {
        XCTAssertEqual(try argv(req(.codex, .threadRead)), try argv(req(.codex, .readOnly)))
        XCTAssertEqual(value(after: "-s", in: try argv(req(.codex, .threadRead))), "read-only")
        XCTAssertEqual(try argv(req(.codex, .threadRead, resume: "s")), try argv(req(.codex, .readOnly, resume: "s")))
    }

    // MARK: gemini

    /// Gemini keeps its planning project's rules, which already allow the reading commands and
    /// deny every writer by name; the argv is exactly the read-only seat's.
    func testGeminiKeepsItsPlanningProject() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("fd-thread-gemini-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let thread = try HeadlessCommand.build(req(.gemini, .threadRead, model: "gemini-3-pro"), home: tmp).arguments
        let readOnly = try HeadlessCommand.build(req(.gemini, .readOnly, model: "gemini-3-pro"), home: tmp).arguments
        XCTAssertEqual(thread, readOnly)
        XCTAssertEqual(value(after: "--project", in: thread), GeminiPlanningProject.id)
    }

    // MARK: grok

    /// Grok and OpenCode thread agents read files only (R1, fix round 2): grok's shell can't be
    /// confined to reading commands, and OpenCode's bash checks path arguments for only a few
    /// commands, so `head ~/.ssh/…` would read past the workspace. The thread header says so.
    func testGrokAndOpenCodeReadFilesOnly() throws {
        let args = try argv(req(.grok, .threadRead))
        XCTAssertEqual(value(after: "--tools", in: args), HeadlessCommand.grokReadOnlyTools)
        XCTAssertTrue(zip(args, args.dropFirst()).contains { $0 == "--deny" && $1 == "Bash" })
        XCTAssertTrue(HeadlessCommand.threadReadsFilesOnly(.grok))
        XCTAssertTrue(HeadlessCommand.threadReadsFilesOnly(.opencode))
        for agent in [AgentID.claude, .codex, .gemini] {
            XCTAssertFalse(HeadlessCommand.threadReadsFilesOnly(agent), "\(agent) runs read commands")
        }
    }


    // MARK: opencode

    /// OpenCode's thread agent, pinned byte for byte: the read-only file tools, bash denied
    /// outright (no allow pattern, so OpenCode removes the tool), and reads outside the repo
    /// only in the workspace.
    func testOpenCodeThreadAgentHasNoBash() throws {
        let command = try HeadlessCommand.build(req(.opencode, .threadRead), home: Self.noHome)
        XCTAssertEqual(value(after: "--agent", in: command.arguments), OpenCodeProfile.threadAgent)
        let env = HeadlessCommand.environment(for: command, base: [:], home: Self.noHome,
                                              readable: [URL(fileURLWithPath: "/intake/threads/t/workspace")])
        let readOnlyAgent = #""flightdeck-readonly":{"description":"Flight Deck planning agent","mode":"primary","permission":{"*":"deny","glob":"allow","grep":"allow","list":"allow","read":"allow"}}"#
        XCTAssertEqual(env["OPENCODE_CONFIG_CONTENT"],
                       #"{"agent":{"# + readOnlyAgent
                       + #","flightdeck-thread":{"description":"Flight Deck planning agent","mode":"primary","permission":{"*":"deny","bash":{"*":"deny"},"external_directory":{"*":"deny","\/intake\/threads\/t\/workspace\/*":"allow"},"glob":"allow","grep":"allow","list":"allow","read":"allow"}}},"autoupdate":false,"share":"disabled"}"#)
    }

    /// I3: the thread agent may read outside the repo only inside the workspace it is handed —
    /// never the whole disk, which `external_directory: allow` let it do (proven live).
    func testOpenCodeThreadReadsOutsideTheRepoOnlyInItsWorkspace() throws {
        let command = try HeadlessCommand.build(req(.opencode, .threadRead), home: Self.noHome)
        let workspace = URL(fileURLWithPath: "/intake/threads/t/workspace")
        let env = HeadlessCommand.environment(for: command, base: [:], home: Self.noHome, readable: [workspace])
        let config = try XCTUnwrap(env["OPENCODE_CONFIG_CONTENT"])
        XCTAssertTrue(config.contains(#""external_directory":{"*":"deny","\/intake\/threads\/t\/workspace\/*":"allow"}"#), config)

        let unscoped = try XCTUnwrap(HeadlessCommand.environment(for: command, base: [:], home: Self.noHome)["OPENCODE_CONFIG_CONTENT"])
        XCTAssertTrue(unscoped.contains(#""external_directory":{"*":"deny"}"#), "no workspace named, nothing outside the repo")
        XCTAssertFalse(unscoped.contains(#""external_directory":"allow""#))
    }

    /// A thread turn never writes, so it is never a write-mode request.
    func testThreadReadIsNotAWriteRequest() {
        XCTAssertNil(HeadlessCommand.validate(req(.claude, .threadRead, resume: "s")))
    }
}
