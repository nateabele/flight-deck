import XCTest
import IntakeKit

final class HarnessWriteModeTests: XCTestCase {
    let dir = URL(fileURLWithPath: "/work")

    func req(_ h: Harness, access: HarnessAccess, cwd: URL? = nil, resume: String? = nil) -> HarnessRequest {
        HarnessRequest(harness: h, model: "m", effort: "high", cwd: cwd ?? dir,
                       readableDirs: [URL(fileURLWithPath: "/intake")], prompt: "P",
                       schemaFile: URL(fileURLWithPath: "/intake/schema.json"), schemaJSON: "{}",
                       resumeSessionID: resume, access: access)
    }

    func testCodexWriteInWorkUsesWorkspaceWriteSandbox() {
        let c = HarnessCommand.build(req(.codex, access: .writeInWork(dir)))
        XCTAssertEqual(c.executable, "codex")
        XCTAssertEqual(c.arguments, ["exec", "--json", "-m", "m", "-c", "model_reasoning_effort=high",
                                     "-s", "workspace-write", "--skip-git-repo-check",
                                     "--output-schema", "/intake/schema.json", "P"])
    }

    func testClaudeWriteInWorkGrantsEditWriteAndAddsWorkDir() {
        let c = HarnessCommand.build(req(.claude, access: .writeInWork(dir)))
        XCTAssertEqual(c.executable, "claude")
        XCTAssertEqual(c.arguments, ["-p", "P", "--model", "m", "--effort", "high", "--output-format", "json",
                                     "--json-schema", "{}", "--permission-mode", "acceptEdits",
                                     "--allowedTools", HarnessCommand.claudeWriteTools,
                                     "--add-dir", "/work", "--add-dir", "/intake"])
        XCTAssertFalse(c.arguments.contains("--disallowedTools"))
    }

    /// `validate` is the pure check `build` traps on — exercised directly so this test never trips
    /// the precondition itself.
    func testValidateRejectsCwdOutsideTheWorkDir() {
        let elsewhere = URL(fileURLWithPath: "/somewhere-else")
        let error = HarnessCommand.validate(req(.codex, access: .writeInWork(dir), cwd: elsewhere))
        XCTAssertEqual(error, .cwdNotWorkDir)
    }

    func testValidateAcceptsCwdMatchingTheWorkDir() {
        XCTAssertNil(HarnessCommand.validate(req(.codex, access: .writeInWork(dir))))
    }

    /// The integrator always starts fresh — `validate` is what `build`'s precondition would trap
    /// on if a caller tried to resume a write-mode run.
    func testValidateRejectsResumeInWriteMode() {
        let error = HarnessCommand.validate(req(.codex, access: .writeInWork(dir), resume: "T1"))
        XCTAssertEqual(error, .resumeNotSupportedForWrite)
    }

    func testValidateIgnoresCwdAndResumeWhenReadOnly() {
        let elsewhere = URL(fileURLWithPath: "/somewhere-else")
        XCTAssertNil(HarnessCommand.validate(req(.codex, access: .readOnly, cwd: elsewhere, resume: "T1")))
    }
}
