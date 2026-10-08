import XCTest
import IntakeKit

/// The Gemini harness against a real `agy`: one read-only drafter run with the real draft
/// schema, one resume of THAT conversation that must remember what the first turn was told,
/// and a read-only check that a seat asked to write a `.md` file leaves no file behind. Every
/// other Gemini test runs on captured fixtures; only this proves the argv `HeadlessCommand`
/// builds still drives the installed `agy`.
///
/// Spends real (minimal) tokens, so it is skipped unless `FLIGHTDECK_GEMINI_LIVE=1` — run it
/// once by hand through `FD_TEST_FILTER=GeminiPlanningLiveTests`. Never loop it. It also skips
/// when `agy models` says signed out: a signed-out `agy -p` starts a Google sign-in in the
/// browser, which a test must never do.
///
/// The scratch project lives under `$HOME`, never `/tmp`, and is removed on every path.
final class GeminiPlanningLiveTests: XCTestCase {
    private var scratch: URL!
    private var environment: [String: String] = [:]
    private let model = "gemini-3.8-flash-low"   // cheap: this probes the agent, not plan quality

    override func setUp() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["FLIGHTDECK_GEMINI_LIVE"] == "1" else {
            throw XCTSkip("live gemini probe: set FLIGHTDECK_GEMINI_LIVE=1 to spend real tokens on it")
        }
        environment = GeminiProfile().environment(base: env, account: nil)
        let check = try await SystemCommandRunner().run(executable: "agy", arguments: GeminiProfile().signInCheck.arguments,
                                                        cwd: FileManager.default.homeDirectoryForCurrentUser,
                                                        environment: environment)
        let readiness = GeminiProfile().signInCheck.readiness(SignInCheckOutput(
            stdout: String(decoding: check.stdout, as: UTF8.self), stderr: check.stderr, exitCode: check.exitCode))
        guard readiness == .ready else { throw XCTSkip("agy is not signed in: \(readiness)") }
        scratch = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".fd-gemini-live-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        try Data("# widget\n\nA tiny dummy project.\n".utf8).write(to: scratch.appendingPathComponent("README.md"))
    }

    override func tearDown() async throws {
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
    }

    /// One seat turn, with the executor's one repair: a turn agy ended on a denied tool is
    /// resumed once on its own conversation (`SchemaRepair`), exactly as a round would.
    private func run(_ prompt: String, resume: String? = nil, isRepair: Bool = false) async throws -> (sessionID: String, plan: String) {
        let schemaFile = scratch.appendingPathComponent("schema-\(UUID().uuidString).json")
        try Data(RoundSchemas.draft.utf8).write(to: schemaFile)
        defer { try? FileManager.default.removeItem(at: schemaFile) }
        let request = HeadlessRequest(agent: .gemini, model: model, effort: "", cwd: scratch, readableDirs: [],
                                     prompt: prompt, schemaFile: schemaFile, schemaJSON: RoundSchemas.draft,
                                     resumeSessionID: resume)
        let command = try HeadlessCommand.build(request)
        let result = try await SystemCommandRunner().run(executable: command.executable, arguments: command.arguments,
                                                         cwd: scratch, environment: environment)
        XCTAssertEqual(result.exitCode, 0, result.stderr)
        do {
            let parsed = try HeadlessOutput.parse(.gemini, stdout: result.stdout)
            let draft = try RoundPrompts.decode(DraftOutput.self, parsed.structured)
            return (parsed.sessionID, draft.plan)
        } catch {
            let diagnosis = FailureDiagnosis.classify(exitCode: 0, stdout: Data(), stderr: "", parseError: error, agent: .gemini)
            guard let repair = SchemaRepair.retry(profile: GeminiProfile(), failure: diagnosis,
                                                  sessionID: HeadlessOutput.reportedSession(.gemini, stdout: result.stdout),
                                                  access: .readOnly, isRepair: isRepair) else { throw error }
            print("GeminiPlanningLiveTests: repairing an answerless turn: \(error)")
            return try await run(repair.prompt, resume: repair.resumeSessionID, isRepair: true)
        }
    }

    func testDraftThenResumeTheSameConversation() async throws {
        let first = try await run("Remember the number 417. Reply with a one-line plan to add a --version flag.")
        XCTAssertFalse(first.sessionID.isEmpty)
        XCTAssertFalse(first.plan.isEmpty)
        let second = try await run("What number did I ask you to remember? Put only that number in plan.", resume: first.sessionID)
        XCTAssertEqual(second.sessionID, first.sessionID, "a resume continues the same conversation")
        XCTAssertTrue(second.plan.contains("417"), second.plan)
    }

    /// A read-only seat must not write — `.md` included (the gemini CLI's plan mode allowed
    /// `*.md` writes, and agy's `--mode plan` wrote files once permissions were skipped).
    func testReadOnlySeatCannotWriteAMarkdownFile() async throws {
        _ = try? await run("Create a file named NOTES.md in the current directory containing the word hi. Then put done in plan.")
        let entries = try FileManager.default.contentsOfDirectory(atPath: scratch.path).filter { !$0.hasPrefix("schema-") }
        XCTAssertEqual(entries, ["README.md"], "a read-only seat wrote: \(entries)")
        XCTAssertEqual(try String(contentsOf: scratch.appendingPathComponent("README.md"), encoding: .utf8),
                       "# widget\n\nA tiny dummy project.\n")
    }
}
