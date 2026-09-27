import XCTest
import IntakeKit

final class HarnessTests: XCTestCase {
    /// A home with no `.codex/config.toml`, so argv never depends on the operator's own config.
    static let noHome = URL(fileURLWithPath: "/nonexistent-fd-home")
    private func load(_ name: String, _ ext: String) throws -> Data {
        try Data(contentsOf: try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: ext, subdirectory: "Fixtures/Intake")))
    }
    func req(_ h: Harness, resume: String? = nil) -> HarnessRequest {
        HarnessRequest(harness: h, model: "m", effort: "high", cwd: URL(fileURLWithPath: "/proj"),
                       readableDirs: [URL(fileURLWithPath: "/intake")], prompt: "P",
                       schemaFile: URL(fileURLWithPath: "/intake/schema.json"), schemaJSON: "{}", resumeSessionID: resume)
    }
    func testCodexParse() throws {
        let out = try HarnessOutput.parse(.codex, stdout: try load("codex-exec-schema", "jsonl"))
        XCTAssertEqual(out.sessionID, "01a0df75-9981-7bd0-9ac1-6c8eed40c469")
        XCTAssertEqual(try JSONSerialization.jsonObject(with: out.structured) as? [String: String], ["answer": "PONG"])
    }
    func testClaudeParsePrefersStructuredOutput() throws {
        let out = try HarnessOutput.parse(.claude, stdout: try load("claude-p-schema", "json"))
        XCTAssertEqual(out.sessionID, "a4861836-f024-45f3-9f11-f3a2d366e96f")
        XCTAssertEqual(try JSONSerialization.jsonObject(with: out.structured) as? [String: String], ["answer": "PONG"])
    }
    func testCodexFreshIsReadOnlyWithSchema() {
        let c = HarnessCommand.build(req(.codex), home: Self.noHome)
        XCTAssertEqual(c.executable, "codex")
        XCTAssertEqual(c.arguments, ["exec", "--json", "-m", "m", "-c", "model_reasoning_effort=high",
                                     "--ignore-user-config", "--ignore-rules", "--disable", "hooks",
                                     "-s", "read-only", "--skip-git-repo-check",
                                     "--output-schema", "/intake/schema.json", "P"])
    }
    func testCodexResumePinsModelAndSandbox() {
        let c = HarnessCommand.build(req(.codex, resume: "T1"), home: Self.noHome)
        XCTAssertEqual(c.arguments, ["exec", "resume", "--json", "-m", "m", "-c", "model_reasoning_effort=high",
                                     "--ignore-user-config", "--ignore-rules", "--disable", "hooks",
                                     "-c", "sandbox_mode=\"read-only\"", "--skip-git-repo-check",
                                     "--output-schema", "/intake/schema.json", "T1", "P"])
    }
    func testClaudeIsReadOnlyAndUnsetsChildSessionEnv() {
        let c = HarnessCommand.build(req(.claude, resume: "S1"), home: Self.noHome)
        XCTAssertEqual(c.executable, "claude")
        XCTAssertEqual(c.unsetEnvironment, ["CLAUDE_CODE_CHILD_SESSION", "CLAUDECODE"])
        XCTAssertEqual(c.arguments, ["-p", "P", "--model", "m", "--effort", "high", "--output-format", "json",
                                     "--json-schema", "{}", "--permission-mode", "dontAsk",
                                     "--tools", "Read Grep Glob Bash",
                                     "--allowedTools", HarnessCommand.claudeReadOnlyTools,
                                     "--disallowedTools", HarnessCommand.claudeDeniedTools,
                                     "--add-dir", "/intake", "--restricted", "--strict-mcp-config",
                                     "--resume", "S1"])
    }
    /// `--allowedTools` only ADDS to the operator's settings.json allows, so a `dontAsk`
    /// read-only seat that loaded them would inherit standing allows like `Bash(git add *)`.
    /// `--restricted` ignores the user, project AND local settings files (where
    /// `--setting-sources local` still kept `settings.local.json`); every claude run, read-only
    /// and write, must carry it and `--strict-mcp-config`, and never the older flag.
    func testEveryClaudeRunIsRestrictedAndDropsMCP() {
        let write = HarnessRequest(harness: .claude, model: "m", effort: "high", cwd: URL(fileURLWithPath: "/work"),
                                   readableDirs: [], prompt: "P", schemaFile: URL(fileURLWithPath: "/s.json"),
                                   schemaJSON: "{}", resumeSessionID: nil, access: .writeInWork(URL(fileURLWithPath: "/work")))
        for r in [req(.claude), req(.claude, resume: "S1"), write] {
            let a = HarnessCommand.build(r, home: Self.noHome).arguments
            XCTAssertEqual(a.filter { $0 == "--restricted" }.count, 1, "\(a)")
            XCTAssertEqual(a.filter { $0 == "--strict-mcp-config" }.count, 1, "\(a)")
            XCTAssertFalse(a.contains("--setting-sources"), "\(a)")
        }
    }
    /// `~/.codex/config.toml` carries MCP servers (qartez, with file mutators) and hooks that
    /// run OUTSIDE the `-s` sandbox. Every codex build — fresh, resume, write — must skip it.
    func testEveryCodexRunIgnoresUserConfigRulesAndHooks() {
        let write = HarnessRequest(harness: .codex, model: "m", effort: "high", cwd: URL(fileURLWithPath: "/work"),
                                   readableDirs: [], prompt: "P", schemaFile: URL(fileURLWithPath: "/s.json"),
                                   schemaJSON: "{}", resumeSessionID: nil, access: .writeInWork(URL(fileURLWithPath: "/work")))
        for r in [req(.codex), req(.codex, resume: "T1"), write] {
            let a = HarnessCommand.build(r, home: Self.noHome).arguments
            for flag in ["--ignore-user-config", "--ignore-rules"] {
                XCTAssertEqual(a.filter { $0 == flag }.count, 1, "\(flag) in \(a)")
            }
            guard let i = a.firstIndex(of: "--disable") else { return XCTFail("hooks not disabled in \(a)") }
            XCTAssertEqual(a[i + 1], "hooks")
        }
    }
    /// `--allowedTools` only ADDS allow rules: a project `.claude/settings.json` allowing
    /// `Bash(br:*)`, or a user `defaultMode: bypassPermissions`, would otherwise let triage
    /// write to `br`. Deny rules beat allow rules, so every `br` write verb is denied by name.
    func testClaudeDeniesEveryBrWriteVerb() {
        for verb in ["create", "update", "close", "reopen", "delete", "dep", "label", "comments",
                     "sync", "defer", "undefer", "q", "init"] {
            XCTAssertTrue(HarnessCommand.claudeDeniedTools.contains("Bash(br \(verb) *)"), verb)
        }
        for read in ["list", "show", "graph", "ready"] {
            XCTAssertFalse(HarnessCommand.claudeDeniedTools.contains("Bash(br \(read)"), read)
        }
    }
    /// Triage (`SystemHeadlessRunner`) and every round (`RoundExecutor`) build a child's
    /// environment through this one function: a claude child gets the user settings' `env`
    /// back (`--restricted` drops the file), PATH/HOME never come from it, and the unsets land
    /// last so the settings file cannot re-introduce `CLAUDECODE`. Codex gets `base` as is.
    func testEnvironmentMergesClaudeSettingsEnvThenUnsets() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("fd-home-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        try Data(#"{"env":{"ANTHROPIC_BASE_URL":"http://localhost:8787","CLAUDECODE":"1","HOME":"/nope"}}"#.utf8)
            .write(to: home.appendingPathComponent(".claude/settings.json"))
        let base = ["PATH": "/usr/bin", "HOME": "/Users/me", "CLAUDE_CODE_CHILD_SESSION": "1"]

        let claude = HarnessCommand.environment(for: HarnessCommand.build(req(.claude), home: Self.noHome), base: base, home: home)
        XCTAssertEqual(claude, ["PATH": "/usr/bin", "HOME": "/Users/me", "ANTHROPIC_BASE_URL": "http://localhost:8787"])
        let codex = HarnessCommand.environment(for: HarnessCommand.build(req(.codex), home: Self.noHome), base: base, home: home)
        XCTAssertEqual(codex, base)
    }
    /// `--ignore-user-config` drops the user's `service_tier`; it's read back (and only it) and
    /// passed on every codex build, fresh and resume. Claude never gets it.
    func testCodexCarriesServiceTierFromUserConfig() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("fd-home-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".codex"), withIntermediateDirectories: true)
        try Data("""
        model = "gpt-6-sol"
        service_tier = "fast"   # the user's choice
        approval_policy = "never"

        [mcp_servers.qartez]
        command = "qartez"
        """.utf8).write(to: home.appendingPathComponent(".codex/config.toml"))

        XCTAssertEqual(CodexUserConfig.serviceTier(home: home), "fast")
        let fresh = HarnessCommand.build(req(.codex), home: home).arguments
        XCTAssertEqual(Array(fresh.prefix(12)), ["exec", "--json", "-m", "m", "-c", "model_reasoning_effort=high",
                                                 "--ignore-user-config", "--ignore-rules", "--disable", "hooks",
                                                 "-c", "service_tier=\"fast\""])
        let resumed = HarnessCommand.build(req(.codex, resume: "T1"), home: home).arguments
        XCTAssertEqual(resumed.filter { $0.hasPrefix("service_tier") }, ["service_tier=\"fast\""])
        XCTAssertFalse(fresh.contains { $0.hasPrefix("model=") || $0.contains("approval_policy") || $0.contains("qartez") },
                       "only service_tier is carried over")
        XCTAssertFalse(HarnessCommand.build(req(.claude), home: home).arguments.contains { $0.contains("service_tier") })
    }

    /// Only a top-level, plain-identifier value counts: a key under a table is some other
    /// setting's, and anything with quotes or spaces can't be spliced into `-c` safely.
    func testServiceTierParseIsConservative() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("fd-home-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".codex"), withIntermediateDirectories: true)
        let file = home.appendingPathComponent(".codex/config.toml")
        let cases: [(String, String?)] = [
            ("service_tier='flex'\n", "flex"),
            ("[profiles.x]\nservice_tier = \"fast\"\n", nil),
            ("service_tier = \"fa\\\" st\"\n", nil),
            ("service_tiers = \"fast\"\n", nil),
            ("# service_tier = \"fast\"\n", nil),
            ("model = \"x\"\n", nil),
        ]
        for (toml, expected) in cases {
            try Data(toml.utf8).write(to: file)
            XCTAssertEqual(CodexUserConfig.serviceTier(home: home), expected, toml)
        }
        XCTAssertNil(CodexUserConfig.serviceTier(home: Self.noHome))
        XCTAssertFalse(HarnessCommand.build(req(.codex), home: Self.noHome).arguments.contains { $0.contains("service_tier") })
    }
    func testProseOutputIsNotJSON() {
        let line1 = "{\"type\":\"thread.started\",\"thread_id\":\"T\"}"
        let line2 = "{\"type\":\"item.completed\",\"item\":{\"type\":\"agent_message\",\"text\":\"Sure! Here you go\"}}"
        let prose = Data((line1 + "\n" + line2).utf8)
        XCTAssertThrowsError(try HarnessOutput.parse(.codex, stdout: prose))
    }
}
