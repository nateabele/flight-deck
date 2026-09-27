import XCTest
import IntakeKit

final class HarnessTests: XCTestCase {
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
        let c = HarnessCommand.build(req(.codex))
        XCTAssertEqual(c.executable, "codex")
        XCTAssertEqual(c.arguments, ["exec", "--json", "-m", "m", "-c", "model_reasoning_effort=high",
                                     "--ignore-user-config", "--ignore-rules", "--disable", "hooks",
                                     "-s", "read-only", "--skip-git-repo-check",
                                     "--output-schema", "/intake/schema.json", "P"])
    }
    func testCodexResumePinsModelAndSandbox() {
        let c = HarnessCommand.build(req(.codex, resume: "T1"))
        XCTAssertEqual(c.arguments, ["exec", "resume", "--json", "-m", "m", "-c", "model_reasoning_effort=high",
                                     "--ignore-user-config", "--ignore-rules", "--disable", "hooks",
                                     "-c", "sandbox_mode=\"read-only\"", "--skip-git-repo-check",
                                     "--output-schema", "/intake/schema.json", "T1", "P"])
    }
    func testClaudeIsReadOnlyAndUnsetsChildSessionEnv() {
        let c = HarnessCommand.build(req(.claude, resume: "S1"))
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
            let a = HarnessCommand.build(r).arguments
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
            let a = HarnessCommand.build(r).arguments
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

        let claude = HarnessCommand.environment(for: HarnessCommand.build(req(.claude)), base: base, home: home)
        XCTAssertEqual(claude, ["PATH": "/usr/bin", "HOME": "/Users/me", "ANTHROPIC_BASE_URL": "http://localhost:8787"])
        let codex = HarnessCommand.environment(for: HarnessCommand.build(req(.codex)), base: base, home: home)
        XCTAssertEqual(codex, base)
    }
    func testProseOutputIsNotJSON() {
        let line1 = "{\"type\":\"thread.started\",\"thread_id\":\"T\"}"
        let line2 = "{\"type\":\"item.completed\",\"item\":{\"type\":\"agent_message\",\"text\":\"Sure! Here you go\"}}"
        let prose = Data((line1 + "\n" + line2).utf8)
        XCTAssertThrowsError(try HarnessOutput.parse(.codex, stdout: prose))
    }
}
