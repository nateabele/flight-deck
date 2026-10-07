import XCTest
import IntakeKit
@testable import FlightDeck

/// The grok `AgentProfile` (grok/gemini spec §3.0, §3.2, §3.6, §3.7): sign-in check, model
/// list, error classification, environment, and what they feed — detection, the Rounds
/// editor, the live activity row and failure diagnosis.
final class GrokProfileTests: XCTestCase {
    private func fixture(_ name: String, _ ext: String) throws -> Data {
        try Data(contentsOf: try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: ext, subdirectory: "Fixtures/Intake")))
    }
    private func text(_ name: String, _ ext: String) throws -> String { String(decoding: try fixture(name, ext), as: UTF8.self) }

    /// A signed-in `grok models` with the default listed LAST, to prove `parseModelList`
    /// moves the `(default)` entry first regardless of where grok prints it.
    static let signedInModels = """
        You are logged in with grok.com.

        Default model: grok-4.6

        Available models:
          - grok-4.5
          * grok-4.6 (default)

        """

    // MARK: Profile

    func testGrokIsNoLongerAStub() {
        let profile = GrokProfile()
        XCTAssertNil(profile.unimplemented)
        XCTAssertFalse(profile.modelCatalog.isEmpty)
        XCTAssertEqual(profile.modelCatalog.defaultPlanningModel, "grok-4.7", "a fallback only; see testParsesTheModelList")
        XCTAssertEqual(profile.modelCatalog.defaultPlanningEffort, "high")
        XCTAssertEqual(profile.modelCatalog.listArguments, ["models"])
        XCTAssertEqual(profile.signInCheck.arguments, ["models"])
        XCTAssertTrue(profile.hasNativeSchema)
    }

    func testParsesTheModelList() throws {
        XCTAssertEqual(GrokProfile().parseModelList(try text("grok-models-signed-out", "txt")), ["grok-4.6", "grok-4.5"])
        // Live, signed in, 2026-10-07: the default had already moved to grok-4.7.
        XCTAssertEqual(GrokProfile().parseModelList(try text("grok-models-signed-in", "txt")),
                       ["grok-4.7", "grok-4.7-build-fast", "grok-4.6", "grok-4.5"])
        XCTAssertEqual(GrokProfile().parseModelList(Self.signedInModels), ["grok-4.6", "grok-4.5"], "(default) first")
        XCTAssertEqual(GrokProfile().parseModelList(""), [])
        XCTAssertEqual(GrokProfile().parseModelList("Default model: grok-4.6\n"), [], "the header is not a model")
    }

    /// Signed out, `grok models` still exits 0 AND prints the model list (real capture) — only
    /// its first line says so. Empty output (a stub `grok`) never reads as signed in either.
    func testSignInCheck() throws {
        let check = GrokProfile().signInCheck
        XCTAssertEqual(check.readiness(SignInCheckOutput(stdout: try text("grok-models-signed-out", "txt"), stderr: "", exitCode: 0)),
                       .signedOut(hint: "Grok: run `grok login`"))
        XCTAssertEqual(check.readiness(SignInCheckOutput(stdout: try text("grok-models-signed-in", "txt"), stderr: "", exitCode: 0)), .ready)
        XCTAssertEqual(check.readiness(SignInCheckOutput(stdout: "", stderr: "", exitCode: 0)), .signedOut(hint: "Grok: run `grok login`"))
        XCTAssertEqual(check.readiness(SignInCheckOutput(stdout: Self.signedInModels, stderr: "", exitCode: 1)),
                       .signedOut(hint: "Grok: run `grok login`"))
    }

    func testClassifiesGroksOwnErrorSpellings() throws {
        let p = GrokProfile()
        XCTAssertEqual(p.classify(error: .stderr(try text("grok-auth-error-stderr", "txt"))), .authExpired)
        XCTAssertEqual(p.classify(error: .stderr("Your session has expired. Run `grok login` to sign in again.")), .authExpired)
        // UNVERIFIED spellings (grok 1.0.30 string table, never provoked live): usage limits.
        for limit in ["You hit your weekly limit.", "You've hit the rate limit for your plan.", "You hit your free usage limit.",
                      "You've hit the credit limit for your plan.", "status 429 Too Many Requests"] {
            XCTAssertEqual(p.classify(error: .stderr(limit)), .rateLimited, limit)
        }
        XCTAssertNil(p.classify(error: .stderr(try text("grok-bad-model-stderr", "txt"))), "a bad model is not auth or a limit")
        let event = #"{"type":"result","is_error":true,"errors":["You hit your weekly limit."],"session_id":""}"#
        XCTAssertEqual(p.classify(error: .streamErrorEvent(json: event)), .rateLimited)
        XCTAssertEqual(p.classify(error: .appServerError(code: 401, message: "Unauthorized")), .authExpired)
    }

    func testEnvironmentBindsTheAccountAndIsolates() {
        let base = ["PATH": "/bin", "HOME": "/Users/op", "CLAUDECODE": "1", "GROK_CURSOR_MCPS_ENABLED": "1"]
        let builtIn = GrokProfile().environment(base: base, account: nil)
        // The built-in account is the operator's own ~/.grok, made explicit, and HOME moves
        // there so grok can't discover ~/.claude/plugins (probed: their hooks loaded otherwise).
        XCTAssertEqual(builtIn["GROK_HOME"], "/Users/op/.grok")
        XCTAssertEqual(builtIn["HOME"], "/Users/op/.grok")
        XCTAssertEqual(builtIn["GROK_CODEX_HOOKS_ENABLED"], "0")
        XCTAssertEqual(GrokProfile().environment(base: ["HOME": "/Users/op", "GROK_HOME": "/custom"], account: nil)["GROK_HOME"],
                       "/custom", "an operator's own GROK_HOME is kept")
        XCTAssertNil(builtIn["CLAUDECODE"])
        XCTAssertEqual(builtIn["GROK_CURSOR_MCPS_ENABLED"], "0")
        XCTAssertEqual(builtIn["GROK_CLAUDE_AGENTS_ENABLED"], "0")
        let bound = GrokProfile().environment(base: base, account: AgentAccountRef(id: "a", home: URL(fileURLWithPath: "/accounts/grok-a")))
        XCTAssertEqual(bound["GROK_HOME"], "/accounts/grok-a")
        XCTAssertEqual(bound["HOME"], "/accounts/grok-a")
    }

    // MARK: Diagnosis

    /// The real signed-out run: stderr AND the `is_error` result both say "Not signed in." —
    /// that is auth, and the action names grok's real sign-in command.
    func testSignedOutRunDiagnosesAsAuth() throws {
        let d = FailureDiagnosis.classify(exitCode: 1, stdout: try fixture("grok-auth-error", "jsonl"),
                                          stderr: try text("grok-auth-error-stderr", "txt"), parseError: nil, harness: .grok)
        XCTAssertEqual(d.category, .authExpired)
        XCTAssertEqual(d.action, "Run `grok login` in a terminal")
    }

    /// A spent SuperGrok pool says neither "rate limit" nor "429" — still `rateLimited`
    /// (UNVERIFIED spelling: from the string table, never provoked).
    func testWeeklyLimitIsRateLimited() {
        let stream = #"{"type":"result","subtype":"error_during_execution","is_error":true,"errors":["You hit your weekly limit."],"session_id":""}"# + "\n"
        let d = FailureDiagnosis.classify(exitCode: 1, stdout: Data(stream.utf8), stderr: "", parseError: nil, harness: .grok)
        XCTAssertEqual(d.category, .rateLimited)
        XCTAssertTrue(d.detail.contains("weekly limit"), "the reason from errors[], not the bare subtype: \(d.detail)")
    }

    /// A model's own prose mentioning limits is content, not a failure signal.
    func testAgentTextNeverClassifies() {
        let stream = #"{"type":"assistant","message":{"content":[{"type":"text","text":"You hit your weekly limit."}]},"session_id":"S"}"# + "\n"
        let d = FailureDiagnosis.classify(exitCode: 1, stdout: Data(stream.utf8), stderr: "boom", parseError: nil, harness: .grok)
        XCTAssertEqual(d.category, .harnessError)
    }

    // MARK: Activity

    /// The live fresh run (grok-4.7, 2026-10-07): a `read_file` with `target_file`, then a
    /// `thinking` block, then the result with usage and cost.
    func testActivityFoldsTheStream() throws {
        var parser = ActivityParser(harness: .grok, project: URL(fileURLWithPath: "/scratch/proj"),
                                    now: { Date(timeIntervalSince1970: 7) })
        parser.feed(try fixture("grok-stream-activity", "jsonl"))
        let a = parser.activity
        XCTAssertEqual(a.headline, "Preparing a JSON response with kind=questions and one project-related question.")
        XCTAssertEqual(a.action, ActivityAction(verb: "Reading", object: "README.md"))
        XCTAssertEqual(a.footprint, [".": 1])
        XCTAssertEqual(a.inputTokens, 11988 + 2816)
        XCTAssertEqual(a.outputTokens, 233)
        XCTAssertEqual(a.costUSD, 0.00910588)
        XCTAssertTrue(a.finished)
        XCTAssertNil(a.error)
        XCTAssertNil(a.rateLimitWindows)
        XCTAssertEqual(a.lastEventAt, Date(timeIntervalSince1970: 7))
    }

    func testActivityReportsTheSignedOutError() throws {
        var parser = ActivityParser(harness: .grok, project: URL(fileURLWithPath: "/p"), now: { Date() })
        parser.feed(try fixture("grok-auth-error", "jsonl"))
        parser.finish(exitCode: 1)
        XCTAssertTrue(parser.activity.error?.hasPrefix("Not signed in.") == true, parser.activity.error ?? "nil")
    }

    // MARK: Availability

    private func bin(_ tools: [String]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fd-grok-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for tool in tools {
            let file = dir.appendingPathComponent(tool)
            try Data("#!/bin/sh\n".utf8).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        }
        return dir
    }

    func testDetectionOffersASignedInGrokWithItsModels() throws {
        let dir = try bin(["claude", "grok"])
        defer { try? FileManager.default.removeItem(at: dir) }
        var probed: [[String]] = []
        let available = TriageSettings.available(path: dir.path) { exe, args in
            XCTAssertEqual(exe, dir.appendingPathComponent("grok").path)
            probed.append(args)
            return SignInCheckOutput(stdout: Self.signedInModels, stderr: "", exitCode: 0)
        }
        XCTAssertEqual(probed, [["models"]], "the list and the sign-in check are one spawn")
        XCTAssertEqual(available.harnesses, [.claude, .grok])
        XCTAssertEqual(available.choice(for: .grok), ModelChoice(harness: .grok, model: "grok-4.6", effort: "high"))
        XCTAssertEqual(available.models[.grok], ["grok-4.6", "grok-4.5"])
        XCTAssertNil(available.unavailable[.grok])
        XCTAssertEqual(available.choice(for: .claude), AvailableModels.defaults.claude, "claude is unchanged")
    }

    func testSignedOutGrokIsUnavailableWithItsHint() throws {
        let dir = try bin(["codex", "grok"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let signedOut = try text("grok-models-signed-out", "txt")
        let available = TriageSettings.available(path: dir.path) { _, _ in SignInCheckOutput(stdout: signedOut, stderr: "", exitCode: 0) }
        XCTAssertEqual(available.harnesses, [.codex])
        XCTAssertEqual(available.unavailable[.grok], "Grok: run `grok login`")
        XCTAssertEqual(RoundConfigEditor.availabilityNotes(available), ["Grok: run `grok login`"])
    }

    func testMissingGrokIsUnavailableNotInstalled() throws {
        let dir = try bin(["codex"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let available = TriageSettings.available(path: dir.path) { _, _ in XCTFail("nothing to probe"); return nil }
        XCTAssertEqual(available.harnesses, [.codex])
        XCTAssertEqual(available.unavailable[.grok], "Grok: not installed")
    }

    /// A probe that can't run (or times out) is signed out, never ready.
    func testAFailedProbeIsSignedOut() throws {
        let dir = try bin(["grok"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let available = TriageSettings.available(path: dir.path) { _, _ in nil }
        XCTAssertNil(available.choice(for: .grok))
        XCTAssertEqual(available.unavailable[.grok], "Grok: run `grok login`")
    }

    /// An account whose list lacks the profile default is seeded with what it does list.
    func testDefaultFallsBackToTheListedModel() throws {
        let dir = try bin(["grok"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let list = "Default model: grok-9\n\nAvailable models:\n  * grok-9 (default)\n"
        let available = TriageSettings.available(path: dir.path) { _, _ in SignInCheckOutput(stdout: list, stderr: "", exitCode: 0) }
        XCTAssertEqual(available.choice(for: .grok)?.model, "grok-9")
    }

    // MARK: Editor

    func testEditorOffersGrokWithItsModelsAndEffort() {
        var available = AvailableModels(choices: [.claude: AvailableModels.defaults.claude!,
                                                  .grok: ModelChoice(harness: .grok, model: "grok-4.6", effort: "high")])
        available.models[.grok] = ["grok-4.6", "grok-4.5"]
        XCTAssertEqual(RoundConfigEditor.harnesses(in: available), [.claude, .grok])
        XCTAssertEqual(RoundConfigEditor.modelSuggestions(for: .grok, detected: available.models[.grok] ?? []), ["grok-4.6", "grok-4.5"])
        XCTAssertEqual(RoundConfigEditor.effortChoices(for: .grok), ["low", "medium", "high", "xhigh"])
        XCTAssertTrue(RoundConfigEditor.availabilityNotes(available).contains { $0.contains("xAI") }, "the data-use note")
    }

    /// The editor's model menu offers the list the CLI printed, replacing the stale aliases.
    func testEditorSuggestsTheDetectedModels() {
        XCTAssertEqual(RoundConfigEditor.modelSuggestions(for: .grok, detected: ["grok-5", "grok-4.7"]), ["grok-5", "grok-4.7"])
        XCTAssertEqual(RoundConfigEditor.modelSuggestions(for: .grok), GrokProfile().modelCatalog.aliases)
    }

    /// Switching a seat to grok seeds grok's own default; a grok seat's fallback is another family.
    func testSwitchingToGrokAndItsFallback() throws {
        let grok = ModelChoice(harness: .grok, model: "grok-4.6", effort: "high")
        let available = AvailableModels(choices: [.codex: AvailableModels.defaults.codex!, .claude: AvailableModels.defaults.claude!, .grok: grok])
        XCTAssertEqual(RoundConfigEditor.otherModel(for: grok, available: available), AvailableModels.defaults.codex)
        XCTAssertEqual(RoundConfigEditor.otherModel(for: AvailableModels.defaults.codex!, available: available), AvailableModels.defaults.claude)
        XCTAssertEqual(RoundConfigEditor.otherModel(for: AvailableModels.defaults.claude!, available: available), AvailableModels.defaults.codex)
        let codex = AvailableModels.defaults.codex!
        let config = RoundConfig(drafters: [Slot(codex)], synthesizer: nil, reviewer: Slot(codex), integrator: codex,
                                 encoder: codex, polisher: nil, refinementCap: 1, polishCap: 0, freshEyesAndDedup: false,
                                 defaultPlay: .toReview, customized: false)
        let switched = RoundConfigEditor.switchingHarness(config, at: .reviewer, to: .grok, available: available)
        XCTAssertEqual(switched.reviewer?.choice, grok)
    }

    /// A claude+grok pair is cross-family (coverage counts Grok as its own family).
    func testGrokIsItsOwnFamily() {
        let grok = ModelChoice(harness: .grok, model: "grok-4.6", effort: "high")
        let claude = AvailableModels.defaults.claude!
        let config = RoundConfig(drafters: [Slot(claude)], synthesizer: nil, reviewer: Slot(claude), integrator: claude,
                                 encoder: claude, polisher: nil, refinementCap: 1, polishCap: 0, freshEyesAndDedup: false,
                                 defaultPlay: .toReview, customized: true, crossReviewer: Slot(grok), crossCheck: .every)
        XCTAssertTrue(config.crossChecks)
        XCTAssertNotEqual(ModelFamily(.grok), ModelFamily(.claude))
    }
}
