import XCTest
import IntakeKit

/// grok as a planning seat against the REAL CLI and account (grok/gemini spec §5): one fresh
/// read-only drafter run with the real round schema, one resume that must remember what the
/// first run was told, and one run that is asked to write a file and must not be able to.
/// Every other grok test runs on fixtures; only this proves the argv `HarnessCommand.build`
/// produces is one grok accepts, signed in, with strict schemas.
///
/// Costs real tokens, so it is skipped unless `FLIGHTDECK_GROK_LIVE=1` — run it by hand, once,
/// through `FD_TEST_FILTER=GrokPlanningLiveTests` (`test-unit.sh` passes its environment to
/// `xctest`). Never loop it. The scratch project lives under `$HOME` and is removed on every path.
final class GrokPlanningLiveTests: XCTestCase {
    private var scratch: URL!
    private var environment: [String: String] = [:]

    override func setUp() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["FLIGHTDECK_GROK_LIVE"] == "1" else {
            throw XCTSkip("grok live probe: set FLIGHTDECK_GROK_LIVE=1 to spend real tokens on it")
        }
        // grok's installer puts it in ~/.local/bin, which an xctest process's PATH may lack.
        var path = env["PATH"] ?? "/usr/bin:/bin"
        path += ":" + FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin").path
        environment = env
        environment["PATH"] = path
        scratch = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".fd-grok-live-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        try Data("# tallyho\n\nA tiny command-line todo list: `tallyho add <text>`, `tallyho list`.\n".utf8)
            .write(to: scratch.appendingPathComponent("README.md"))
    }

    override func tearDown() async throws {
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
    }

    private func run(_ prompt: String, resume: String? = nil) async throws -> (CommandResult, sessionID: String, plan: String) {
        let request = HarnessRequest(harness: .grok, model: GrokProfile().modelCatalog.defaultPlanningModel, effort: "low", cwd: scratch, readableDirs: [],
                                     prompt: prompt, schemaFile: scratch.appendingPathComponent("unused-schema.json"),
                                     schemaJSON: RoundSchemas.draft, resumeSessionID: resume)
        let command = try HarnessCommand.build(request)
        let result = try await SystemCommandRunner().run(
            executable: command.executable, arguments: command.arguments, cwd: scratch,
            environment: HarnessCommand.environment(for: command, base: environment))
        XCTAssertEqual(result.exitCode, 0, "stderr: \(result.stderr)")
        let parsed = try HarnessOutput.parse(.grok, stdout: result.stdout)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: parsed.structured) as? [String: Any])
        return (result, parsed.sessionID, try XCTUnwrap(object["plan"] as? String))
    }

    func testDraftResumeAndReadOnly() async throws {
        let first = try await run("Read README.md, then reply with a two-sentence plan for adding a `done <n>` command. "
                                  + "Also remember the number 4817 for later.")
        XCTAssertFalse(first.plan.isEmpty)
        XCTAssertNotNil(UUID(uuidString: first.sessionID))

        let second = try await run("What number did I ask you to remember? Put only its digits in `plan`.", resume: first.sessionID)
        XCTAssertEqual(second.sessionID, first.sessionID, "a resume continues the same conversation")
        XCTAssertTrue(second.plan.contains("4817"), second.plan)

        let pwned = scratch.appendingPathComponent("pwned.txt")
        let third = try await run("Create a file named pwned.txt in the current directory containing the word hello, "
                                  + "then put what you did in `plan`.")
        XCTAssertFalse(FileManager.default.fileExists(atPath: pwned.path), "a read-only seat wrote a file: \(third.plan)")
    }
}
