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

    func testClaudeReadOnlyIsUnchanged() throws {
        let args = try argv(req(.claude, .readOnly))
        XCTAssertEqual(value(after: "--allowedTools", in: args), HeadlessCommand.claudeReadOnlyTools)
        XCTAssertEqual(value(after: "--disallowedTools", in: args), HeadlessCommand.claudeDeniedTools)
        XCTAssertEqual(value(after: "--tools", in: args), HeadlessCommand.claudeReadOnlyBuiltins)
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

    /// Grok has no way to scope a shell to reading commands, so a thread turn gets the file
    /// tools only and Bash stays denied; the thread header says so.
    func testGrokReadsFilesOnly() throws {
        let args = try argv(req(.grok, .threadRead))
        XCTAssertEqual(value(after: "--tools", in: args), HeadlessCommand.grokReadOnlyTools)
        XCTAssertTrue(zip(args, args.dropFirst()).contains { $0 == "--deny" && $1 == "Bash" })
        XCTAssertTrue(HeadlessCommand.threadReadsFilesOnly(.grok))
        for agent in [AgentID.claude, .codex, .gemini, .opencode] {
            XCTAssertFalse(HeadlessCommand.threadReadsFilesOnly(agent), "\(agent) runs read commands")
        }
    }

    func testGrokReadOnlyIsUnchanged() throws {
        // The minted session id differs per build; everything before it must match.
        let thread = try argv(req(.grok, .threadRead)), readOnly = try argv(req(.grok, .readOnly))
        XCTAssertEqual(Array(thread.dropLast()), Array(readOnly.dropLast()))
    }

    // MARK: opencode

    /// OpenCode gets its own agent, defined in `OPENCODE_CONFIG_CONTENT`: the read-only tools,
    /// plus `permission.bash` patterns for the read commands and denies for their writing flags.
    func testOpenCodeGetsAThreadAgentWithBashPatterns() throws {
        let command = try HeadlessCommand.build(req(.opencode, .threadRead), home: Self.noHome)
        XCTAssertEqual(value(after: "--agent", in: command.arguments), OpenCodeProfile.threadAgent)
        let env = HeadlessCommand.environment(for: command, base: [:], home: Self.noHome)
        let config = try XCTUnwrap(env["OPENCODE_CONFIG_CONTENT"])
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(config.utf8)) as? [String: Any])
        let agents = try XCTUnwrap(object["agent"] as? [String: Any])
        let thread = try XCTUnwrap(agents[OpenCodeProfile.threadAgent] as? [String: Any])
        let permission = try XCTUnwrap(thread["permission"] as? [String: Any])
        XCTAssertEqual(permission["*"] as? String, "deny")
        XCTAssertEqual(permission["read"] as? String, "allow")
        XCTAssertNil(permission["edit"], "no edit rule: `*: deny` removes the tool")
        let bash = try XCTUnwrap(permission["bash"] as? [String: String])
        XCTAssertEqual(bash["*"], "deny")
        for pattern in ["rg *", "git log *", "git show *", "git diff *", "git blame *", "git grep *", "ls *", "cat *",
                        "head *", "wc *", "find *"] {
            XCTAssertEqual(bash[pattern], "allow", pattern)
        }
        for pattern in ["find *-delete*", "find *-exec*", "git diff *--output*", "rg *--pre*", "cat *>*"] {
            XCTAssertEqual(bash[pattern], "deny", pattern)
        }
        // Each deny names its command first, so in the sorted config it follows that command's
        // allow: whichever way OpenCode orders overlapping rules, the deny is never shadowed by
        // a broader allow sorted after it.
        let keys = bash.keys.sorted()
        for (pattern, decision) in bash where decision == "deny" && pattern != "*" {
            let allowIndex = try XCTUnwrap(keys.firstIndex { bash[$0] == "allow" && pattern.hasPrefix($0.dropLast()) })
            XCTAssertLessThan(allowIndex, try XCTUnwrap(keys.firstIndex(of: pattern)), pattern)
        }
    }

    func testOpenCodeReadOnlyConfigIsUnchanged() throws {
        let command = try HeadlessCommand.build(req(.opencode, .readOnly), home: Self.noHome)
        let env = HeadlessCommand.environment(for: command, base: [:], home: Self.noHome)
        XCTAssertEqual(env["OPENCODE_CONFIG_CONTENT"],
                       OpenCodeProfile.configContent(writeDir: nil, fileExists: { FileManager.default.fileExists(atPath: $0) }))
        XCTAssertEqual(value(after: "--agent", in: command.arguments), OpenCodeProfile.readOnlyAgent)
    }

    /// A thread turn never writes, so it is never a write-mode request.
    func testThreadReadIsNotAWriteRequest() {
        XCTAssertNil(HeadlessCommand.validate(req(.claude, .threadRead, resume: "s")))
    }
}
