import XCTest
import IntakeKit

final class HarnessWriteModeTests: XCTestCase {
    /// A home with no `.codex/config.toml`, so argv never depends on the operator's own config.
    static let noHome = URL(fileURLWithPath: "/nonexistent-fd-home")
    let dir = URL(fileURLWithPath: "/work")

    func req(_ h: AgentID, access: HeadlessAccess, cwd: URL? = nil, resume: String? = nil) -> HeadlessRequest {
        HeadlessRequest(agent: h, model: "m", effort: "high", cwd: cwd ?? dir,
                       readableDirs: [URL(fileURLWithPath: "/intake")], prompt: "P",
                       schemaFile: URL(fileURLWithPath: "/intake/schema.json"), schemaJSON: "{}",
                       resumeSessionID: resume, access: access)
    }

    func testCodexWriteInWorkUsesWorkspaceWriteSandbox() throws {
        let c = try HeadlessCommand.build(req(.codex, access: .writeInWork(dir)), home: Self.noHome)
        XCTAssertEqual(c.executable, "codex")
        XCTAssertEqual(c.arguments, ["exec", "--json", "-m", "m", "-c", "model_reasoning_effort=high",
                                     "--ignore-user-config", "--ignore-rules", "--disable", "hooks", "-c", "model_reasoning_summary=detailed",
                                     "-s", "workspace-write",
                                     "-c", "sandbox_workspace_write.exclude_tmpdir_env_var=true",
                                     "-c", "sandbox_workspace_write.exclude_slash_tmp=true",
                                     "-c", "sandbox_workspace_write.writable_roots=[]",
                                     "--skip-git-repo-check",
                                     "--output-schema", "/intake/schema.json", "P"])
    }

    func testClaudeWriteInWorkGrantsEditWriteAndAddsOnlyTheWorkDir() throws {
        let c = try HeadlessCommand.build(req(.claude, access: .writeInWork(dir)), home: Self.noHome)
        XCTAssertEqual(c.executable, "claude")
        XCTAssertEqual(c.arguments, ["-p", "P", "--model", "m", "--effort", "high", "--output-format", "stream-json",
                                     "--verbose", "--json-schema", "{}", "--permission-mode", "acceptEdits",
                                     "--tools", "Read Edit Write",
                                     "--allowedTools", HeadlessCommand.claudeWriteTools,
                                     "--disallowedTools", HeadlessCommand.claudeWriteDeniedTools,
                                     "--add-dir", "/work", "--restricted", "--strict-mcp-config"])
    }

    /// `--allowedTools` only ADDS to whatever the operator's settings.json already allows —
    /// this machine's has standing allows for `Bash(git add *)` and `Bash(rg:*)` that
    /// `acceptEdits` would otherwise still run. A bare `Bash` deny is what actually holds even
    /// though write mode never lists Bash in `--allowedTools`.
    func testClaudeWriteInWorkAlwaysDeniesBash() throws {
        let c = try HeadlessCommand.build(req(.claude, access: .writeInWork(dir)), home: Self.noHome)
        guard let i = c.arguments.firstIndex(of: "--disallowedTools") else {
            return XCTFail("write mode must pass --disallowedTools")
        }
        XCTAssertTrue(c.arguments[i + 1].split(separator: " ").contains("Bash"))
    }

    /// Every `--add-dir` also grants Edit/Write, so a non-empty `readableDirs` must never widen
    /// write access beyond the integrator's own work dir.
    func testClaudeWriteInWorkNeverAddsReadableDirs() throws {
        let c = try HeadlessCommand.build(req(.claude, access: .writeInWork(dir)), home: Self.noHome)
        let addDirValues = c.arguments.indices.filter { c.arguments[$0] == "--add-dir" }.map { c.arguments[$0 + 1] }
        XCTAssertEqual(addDirValues, ["/work"])
    }

    /// `validate` is the pure check `build` traps on — exercised directly so this test never trips
    /// the precondition itself.
    func testValidateRejectsCwdOutsideTheWorkDir() {
        let elsewhere = URL(fileURLWithPath: "/somewhere-else")
        let error = HeadlessCommand.validate(req(.codex, access: .writeInWork(dir), cwd: elsewhere))
        XCTAssertEqual(error, .cwdNotWorkDir)
    }

    func testValidateAcceptsCwdMatchingTheWorkDir() {
        XCTAssertNil(HeadlessCommand.validate(req(.codex, access: .writeInWork(dir))))
    }

    /// The integrator always starts fresh — `validate` is what `build`'s precondition would trap
    /// on if a caller tried to resume a write-mode run.
    func testValidateRejectsResumeInWriteMode() {
        let error = HeadlessCommand.validate(req(.codex, access: .writeInWork(dir), resume: "T1"))
        XCTAssertEqual(error, .resumeNotSupportedForWrite)
    }

    func testValidateIgnoresCwdAndResumeWhenReadOnly() {
        let elsewhere = URL(fileURLWithPath: "/somewhere-else")
        XCTAssertNil(HeadlessCommand.validate(req(.codex, access: .readOnly, cwd: elsewhere, resume: "T1")))
    }
}
