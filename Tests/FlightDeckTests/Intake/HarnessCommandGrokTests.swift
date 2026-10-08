import XCTest
import IntakeKit

/// grok as a planning harness (grok/gemini spec §3.3, §3.5): the exact argv for fresh, resumed
/// and integrator runs, and the read-only guarantees that hold no matter what the operator's
/// own grok or Claude settings allow.
final class HarnessCommandGrokTests: XCTestCase {
    private static let noHome = URL(fileURLWithPath: "/nonexistent-fd-home")

    private func req(resume: String? = nil, effort: String = "high", access: HeadlessAccess = .readOnly,
                     cwd: String = "/proj") -> HeadlessRequest {
        HeadlessRequest(agent: .grok, model: "grok-4.6", effort: effort, cwd: URL(fileURLWithPath: cwd),
                       readableDirs: [URL(fileURLWithPath: "/intake")], prompt: "P",
                       schemaFile: URL(fileURLWithPath: "/intake/schema.json"), schemaJSON: "{}",
                       resumeSessionID: resume, access: access)
    }

    private func value(after flag: String, in args: [String]) -> String? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    func testFreshReadOnlyArgv() throws {
        let c = try HeadlessCommand.build(req(), home: Self.noHome)
        XCTAssertEqual(c.executable, "grok")
        XCTAssertEqual(c.unsetEnvironment, [])
        let minted = try XCTUnwrap(value(after: "--session-id", in: c.arguments))
        XCTAssertEqual(c.arguments, ["-p", "P", "--json-schema", "{}", "-m", "grok-4.6", "--reasoning-effort", "high",
                                     "--cwd", "/proj", "--output-format", "streaming-messages-json",
                                     "--disable-web-search", "--no-subagents", "--no-plan", "--disallowed-tools", "Agent",
                                     "--permission-mode", "dontAsk", "--tools", "read_file,grep,list_dir",
                                     "--deny", "Edit", "--deny", "Write", "--deny", "Bash", "--deny", "WebFetch",
                                     "--deny", "WebSearch", "--deny", "MCPTool",
                                     "--deny", "Read(**/.git/**)", "--deny", "Read(**/.beads/**)", "--session-id", minted])
    }

    /// No grok seat, read-only or integrator, may read `.git` or `.beads` metadata. The first
    /// live three-family round's grok reviewer spent 8 of its 26 tool calls there (git config,
    /// `info/exclude`, the beads DB metadata) — context every later turn re-sends, with nothing
    /// in it a plan review can use. `Read(<glob>)` denies cover `read_file`, `grep` and
    /// `list_dir` (probed on grok 1.0.30, 2026-10-07: "deny rule on read matching \"**/.git/**\"").
    func testNoSeatReadsGitOrBeadsMetadata() throws {
        let work = URL(fileURLWithPath: "/intake/work")
        for access in [HeadlessAccess.readOnly, .writeInWork(work)] {
            let args = try HeadlessCommand.build(req(access: access, cwd: access == .readOnly ? "/proj" : "/intake/work"),
                                                home: Self.noHome).arguments
            var denied: [String] = []
            for (i, a) in args.enumerated() where a == "--deny" { denied.append(args[i + 1]) }
            XCTAssertTrue(denied.contains("Read(**/.git/**)"), "\(access): \(denied)")
            XCTAssertTrue(denied.contains("Read(**/.beads/**)"), "\(access): \(denied)")
        }
    }

    /// Every fresh seat gets its OWN new UUID — two parallel seats on grok in the same project
    /// must never share a conversation, and grok refuses a `--session-id` that already exists.
    func testEachFreshSeatMintsItsOwnUUID() throws {
        let a = try XCTUnwrap(value(after: "--session-id", in: try HeadlessCommand.build(req(), home: Self.noHome).arguments))
        let b = try XCTUnwrap(value(after: "--session-id", in: try HeadlessCommand.build(req(), home: Self.noHome).arguments))
        XCTAssertNotNil(UUID(uuidString: a))
        XCTAssertNotNil(UUID(uuidString: b))
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(a, a.lowercased())
    }

    /// A resume names the seat's own id and never mints a second one (grok only accepts
    /// `--session-id` with `--resume` alongside `--fork-session`). Bare `--resume`/`--continue`
    /// would pick the most recent session in the cwd — with parallel seats, another seat's.
    func testResumeUsesTheSeatsOwnIDOnly() throws {
        let args = try HeadlessCommand.build(req(resume: "0199c1a2-4b7e-7000-8000-00000000a001"), home: Self.noHome).arguments
        XCTAssertEqual(value(after: "--resume", in: args), "0199c1a2-4b7e-7000-8000-00000000a001")
        XCTAssertFalse(args.contains("--session-id"))
        XCTAssertFalse(args.contains("--continue"))
        XCTAssertFalse(args.contains("-c"))
        XCTAssertFalse(args.contains("--fork-session"))
        XCTAssertEqual(Array(args.suffix(2)), ["--resume", "0199c1a2-4b7e-7000-8000-00000000a001"])
    }

    /// No read-only argv ever allows an edit or exec tool, or grants a write-capable built-in.
    func testReadOnlyNeverAllowsAWriteOrExecTool() throws {
        for resume in [nil, "S1"] as [String?] {
            let args = try HeadlessCommand.build(req(resume: resume), home: Self.noHome).arguments
            XCTAssertFalse(args.contains("--allow"), "\(args)")
            XCTAssertFalse(args.contains("--always-approve"))
            XCTAssertFalse(args.contains("--yolo"))
            XCTAssertEqual(value(after: "--permission-mode", in: args), "dontAsk")
            let tools = try XCTUnwrap(value(after: "--tools", in: args)).split(separator: ",").map(String.init)
            XCTAssertEqual(Set(tools), ["read_file", "grep", "list_dir"])
            var denied: [String] = []
            for (i, a) in args.enumerated() where a == "--deny" { denied.append(args[i + 1]) }
            XCTAssertEqual(Set(denied), ["Edit", "Write", "Bash", "WebFetch", "WebSearch", "MCPTool",
                                         "Read(**/.git/**)", "Read(**/.beads/**)"])
            XCTAssertTrue(args.contains("--disable-web-search"))
            XCTAssertEqual(value(after: "--disallowed-tools", in: args), "Agent")
        }
    }

    /// An empty effort is "the model's default": the flag is left off rather than sent empty.
    func testEmptyEffortOmitsTheFlag() throws {
        let args = try HeadlessCommand.build(req(effort: ""), home: Self.noHome).arguments
        XCTAssertFalse(args.contains("--reasoning-effort"))
    }

    /// The integrator may edit ONLY inside its work dir: an `Edit(<dir>/**)` allow under
    /// `dontAsk`, still no shell and no network.
    func testIntegratorWritesOnlyInItsWorkDir() throws {
        let work = URL(fileURLWithPath: "/intake/work")
        let args = try HeadlessCommand.build(req(access: .writeInWork(work), cwd: "/intake/work"), home: Self.noHome).arguments
        XCTAssertEqual(value(after: "--cwd", in: args), "/intake/work")
        XCTAssertEqual(value(after: "--permission-mode", in: args), "dontAsk")
        XCTAssertEqual(value(after: "--tools", in: args), "read_file,grep,list_dir,search_replace,write")
        var allowed: [String] = [], denied: [String] = []
        for (i, a) in args.enumerated() {
            if a == "--allow" { allowed.append(args[i + 1]) }
            if a == "--deny" { denied.append(args[i + 1]) }
        }
        XCTAssertEqual(allowed, ["Edit(/intake/work/**)"])
        XCTAssertEqual(Set(denied), ["Bash", "WebFetch", "WebSearch", "MCPTool", "Read(**/.git/**)", "Read(**/.beads/**)"])
        XCTAssertNotNil(value(after: "--session-id", in: args))
    }

    func testIntegratorWithAResumeIsRefused() {
        let work = URL(fileURLWithPath: "/intake/work")
        XCTAssertEqual(HeadlessCommand.validate(req(resume: "S1", access: .writeInWork(work), cwd: "/intake/work")),
                       .resumeNotSupportedForWrite)
    }

    /// The isolation is environment, not argv: every grok child gets the variables that stop it
    /// reading the operator's Claude/Cursor hooks and MCP servers, whatever `base` held.
    func testEveryGrokChildGetsTheIsolationEnvironment() throws {
        let c = try HeadlessCommand.build(req(), home: Self.noHome)
        let env = HeadlessCommand.environment(for: c, base: ["PATH": "/bin", "GROK_CLAUDE_HOOKS_ENABLED": "1",
                                                           "CLAUDE_CODE_CHILD_SESSION": "1", "HTTPS_PROXY": "http://proxy:1"],
                                             home: Self.noHome)
        for (key, value) in GrokProfile.isolationEnvironment { XCTAssertEqual(env[key], value, key) }
        XCTAssertEqual(env["GROK_CLAUDE_HOOKS_ENABLED"], "0")
        XCTAssertEqual(env["HTTPS_PROXY"], "http://proxy:1", "a proxy must survive isolation")
        XCTAssertEqual(env["PATH"], "/bin")
        XCTAssertNil(env["CLAUDE_CODE_CHILD_SESSION"])
        XCTAssertNil(env["GROK_HOME"], "no HOME in base: nothing to bind")
    }
}
