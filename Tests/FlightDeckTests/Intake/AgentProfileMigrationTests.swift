import XCTest
import IntakeKit
@testable import FlightDeck

/// Track P of the grok/gemini planning spec (§3.0): claude and codex become real profiles, and
/// every duplicate reads them. Two kinds of test live here, deliberately kept apart:
/// - REGRESSION tests pin that a migrated call site answers exactly what it answered before,
///   usually against a verbatim copy of the old code (`legacy…`), for every spelling any old
///   list held;
/// - DRIFT tests pin the two intended changes: `fable` known to planning and routing, and one
///   merged error vocabulary reaching every consumer.
final class AgentProfileMigrationTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("AgentProfileMigrationTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func write(_ text: String, to path: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func req(_ h: AgentID, account: AgentAccountRef? = nil) -> HeadlessRequest {
        HeadlessRequest(agent: h, model: "m", effort: "high", cwd: URL(fileURLWithPath: "/proj"), readableDirs: [],
                       prompt: "P", schemaFile: URL(fileURLWithPath: "/s.json"), schemaJSON: "{}",
                       resumeSessionID: nil, account: account)
    }

    // MARK: - The profiles are real

    func testClaudeAndCodexAreNoLongerStubs() {
        for agent in [AgentID.claude, .codex] {
            let profile = AgentProfiles.profile(for: agent)
            XCTAssertNil(profile.unimplemented, "\(agent)")
            XCTAssertFalse(profile.modelCatalog.isEmpty, "\(agent)")
            XCTAssertFalse(profile.signInCheck.arguments.isEmpty, "\(agent)")
        }
    }

    /// Shapes probed 2026-10-07 (claude 2.1.293 `auth status`, codex-cli 0.160.0 `login status`),
    /// reproduced synthetically.
    func testClaudeSignInCheckNeedsLoggedInAndExitZero() {
        let check = ClaudeProfile().signInCheck
        XCTAssertEqual(check.arguments, ["auth", "status"])
        XCTAssertEqual(check.readiness(SignInCheckOutput(stdout: #"{"loggedIn": true, "authMethod": "claude.ai"}"#, stderr: "", exitCode: 0)), .ready)
        let signedOut = AgentReadiness.signedOut(hint: "Claude: run `claude auth login` in a terminal")
        XCTAssertEqual(check.readiness(SignInCheckOutput(stdout: #"{"loggedIn": false, "authMethod": "none"}"#, stderr: "", exitCode: 1)), signedOut)
        XCTAssertEqual(check.readiness(SignInCheckOutput(stdout: #"{"loggedIn": true}"#, stderr: "", exitCode: 1)), signedOut)
        XCTAssertEqual(check.readiness(SignInCheckOutput(stdout: "Logged in", stderr: "", exitCode: 0)), signedOut,
                       "prose is not proof")
    }

    func testCodexSignInCheckReadsTheExitCode() {
        let check = CodexProfile().signInCheck
        XCTAssertEqual(check.arguments, ["login", "status"])
        XCTAssertEqual(check.readiness(SignInCheckOutput(stdout: "", stderr: "Logged in using ChatGPT", exitCode: 0)), .ready)
        XCTAssertEqual(check.readiness(SignInCheckOutput(stdout: "", stderr: "Not logged in", exitCode: 1)),
                       .signedOut(hint: "Codex: run `codex login` in a terminal"))
    }

    // MARK: - Models and defaults (regression)

    func testPlanningAndTriageDefaultsAreUnchanged() {
        XCTAssertEqual(AvailableModels.defaults.codex, ModelChoice(agent: .codex, model: "gpt-6-sol", effort: "high"))
        XCTAssertEqual(AvailableModels.defaults.claude, ModelChoice(agent: .claude, model: "opus", effort: "high"))
        XCTAssertEqual(TriageSettings.codexDefault, TriageSettings(agent: .codex, model: "gpt-6-sol", effort: "high"))
        XCTAssertEqual(TriageSettings.claudeDefault, TriageSettings(agent: .claude, model: "opus", effort: "high"))
    }

    func testSettingsFlagCatalogOffersTheSameModelsAndEfforts() {
        func choices(_ flag: String) -> [String]? {
            guard let spec = ClaudeFlagCatalog.all.first(where: { $0.canonical == flag }),
                  case .choice(let values, _) = spec.kind else { return nil }
            return values
        }
        XCTAssertEqual(choices("--model"), ["fable", "opus", "sonnet", "haiku"])
        XCTAssertEqual(choices("--effort"), ["low", "medium", "high", "xhigh", "max"])
        XCTAssertEqual(RoundConfigEditor.effortChoices, ["low", "medium", "high", "xhigh", "max"])
        XCTAssertEqual(RoundConfigEditor.effortChoices(for: .claude), RoundConfigEditor.effortChoices)
        XCTAssertEqual(RoundConfigEditor.effortChoices(for: .codex), RoundConfigEditor.effortChoices,
                       "the editor offered codex seats this same list before")
    }

    func testCodexListParsingIsTheRoutingCatalogsAndTheProfiles() throws {
        let data = try RoutingFixtures.data("codex-model-list.json")
        let result = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let ids = CodexProfile().parseModelList(String(decoding: data, as: UTF8.self))
        XCTAssertEqual(ids, ["gpt-6.1-sol", "gpt-6-astra", "gpt-6-sol", "gpt-6-luna",
                             "gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna", "gpt-5.5"])
        XCTAssertEqual(CodexRoutingCatalog.parse(result).0.map(\.id), ids)
        XCTAssertEqual(CodexProfile().parseModelList("not json"), [])
        XCTAssertNil(CodexProfile.catalog.listArguments, "model/list is an RPC, not an argv command")
    }

    // MARK: - Drift fix: fable is known to planning and routing

    func testFableIsKnownToPlanningAndRouting() {
        XCTAssertTrue(ClaudeProfile().modelCatalog.aliases.contains("fable"))
        XCTAssertEqual(RoundConfigEditor.modelSuggestions(for: .claude), ["fable", "opus", "sonnet", "haiku"])
        XCTAssertEqual(ClaudeRoutingCatalog.models.map(\.id), ["opus", "fable", "sonnet", "haiku"],
                       "the profile's default first, for the registry's default-model rule")
        XCTAssertEqual(ClaudeRoutingCatalog.knobSchema, ["effort": ClaudeProfile.catalog.effortValues])
    }

    func testCodexSuggestionsAreItsListWhenKnownElseItsDefault() {
        XCTAssertEqual(RoundConfigEditor.modelSuggestions(for: .codex), ["gpt-6-sol"])
        XCTAssertEqual(RoundConfigEditor.modelSuggestions(for: .codex, codexListed: ["gpt-6.1-sol", "gpt-6-sol"]),
                       ["gpt-6.1-sol", "gpt-6-sol"])
        XCTAssertEqual(RoundConfigEditor.modelSuggestions(for: .claude, codexListed: ["gpt-6.1-sol"]),
                       ["fable", "opus", "sonnet", "haiku"], "codex's list never leaks into claude's")
    }

    // MARK: - Error classification (regression: every old spelling)

    /// `RateLimitClassifier.kinds` as it was, verbatim.
    private static let legacyRateLimitKinds: Set<String> = ["rate_limit", "rate_limit_exceeded", "usage_limit_exceeded", "usage_limit_reached"]
    /// `CodexTurnRecovery.transientKinds` as it was, verbatim.
    private static let legacyCodexTransient: Set<String> = [
        "rate_limit_exceeded", "server_overloaded", "internal_server_error", "response_too_many_failed_attempts",
        "response_stream_connection_failed", "response_stream_disconnected", "http_connection_failed",
    ]
    /// `ClaudeSession`'s two hard-coded transient kinds, verbatim.
    private static let legacyClaudeTransient: Set<String> = ["overloaded", "server_error"]

    private static var everyOldSpelling: Set<String> {
        legacyRateLimitKinds.union(legacyCodexTransient).union(legacyClaudeTransient)
            .union(["invalid_request", "unknown_kind", ""])
    }

    func testEveryOldRateLimitSpellingStillClassifiesTheSame() {
        for kind in Self.everyOldSpelling {
            XCTAssertEqual(RateLimitClassifier.isRateLimit(status: nil, kind: kind), Self.legacyRateLimitKinds.contains(kind), kind)
            XCTAssertTrue(RateLimitClassifier.isRateLimit(status: 429, kind: kind), kind)
        }
        XCTAssertFalse(RateLimitClassifier.isRateLimit(status: 529, kind: "overloaded"))
        XCTAssertFalse(RateLimitClassifier.isRateLimit(status: nil, kind: nil))
        XCTAssertEqual(RateLimitClassifier.kinds, Self.legacyRateLimitKinds)
    }

    func testEveryOldCodexTransientSpellingStillRetries() {
        for kind in Self.legacyCodexTransient {
            XCTAssertTrue(CodexTurnRecovery.isTransientKind(kind), kind)
        }
        for kind in ["usage_limit_exceeded", "usage_limit_reached", "rate_limit", "invalid_request", "unauthorized", ""] {
            XCTAssertFalse(CodexTurnRecovery.isTransientKind(kind), "\(kind) must not auto-retry")
        }
        XCTAssertFalse(CodexTurnRecovery.isTransientKind(nil))
    }

    func testClaudesOwnTransientKindsStillRetryWithoutTheFlag() {
        for kind in Self.legacyClaudeTransient {
            XCTAssertTrue(ClaudeProfile().isTransient(apiErrorKind: kind), kind)
            let line = #"{"type":"assistant","isApiErrorMessage":true,"error":"\#(kind)","message":{"content":[]}}"#
            guard case .apiError(let e)? = ClaudeSession.events(inLine: line, sessionID: UUID()).first else {
                return XCTFail("expected an apiError for \(kind)")
            }
            XCTAssertTrue(e.isTransient, kind)
        }
        let line = #"{"type":"assistant","isApiErrorMessage":true,"error":"rate_limit","message":{"content":[]}}"#
        guard case .apiError(let e)? = ClaudeSession.events(inLine: line, sessionID: UUID()).first else { return XCTFail() }
        XCTAssertFalse(e.isTransient, "claude's own flag, absent here, is what decides a rate_limit")
    }

    /// `FailureDiagnosis.classify`'s rate-limit/auth decision before profiles, verbatim.
    private static func legacyDiagnosis(_ stderr: String, agent: AgentID?) -> (DiagnosisCategory, String)? {
        let haystack = stderr.lowercased()
        if haystack.contains("rate limit") || haystack.contains("429") || haystack.contains("usage limit") {
            return (.rateLimited, "Wait for the limit to reset, or switch this slot to another model.")
        }
        if haystack.contains("not logged in") || haystack.contains("authentication") || haystack.contains("unauthorized")
            || haystack.contains("401") || haystack.contains("/login") || haystack.contains("codex login")
            || haystack.contains("invalid api key") {
            if haystack.contains("codex login") { return (.authExpired, "Run `codex login` in a terminal") }
            if haystack.contains("claude /login") { return (.authExpired, "Run `claude /login` in a terminal") }
            return (.authExpired, agent == .codex ? "Run `codex login` in a terminal" : "Run `claude /login` in a terminal")
        }
        return nil
    }

    func testEveryOldDiagnosisPhraseClassifiesTheSame() {
        let corpus = ["Error: Rate limit exceeded", "HTTP 429", "You hit your USAGE LIMIT", "Not logged in",
                      "Authentication failed", "401 Unauthorized", "Please run /login", "run `codex login` first",
                      "Invalid API key", "Please run claude /login", "429 and also unauthorized", "segfault",
                      "the server is overloaded", ""]
        for agent in [AgentID?.none, .claude, .codex] {
            for stderr in corpus {
                let d = FailureDiagnosis.classify(exitCode: 1, stdout: Data(), stderr: stderr, parseError: nil, agent: agent)
                if let (category, action) = Self.legacyDiagnosis(stderr, agent: agent) {
                    XCTAssertEqual(d.category, category, "\(stderr) / \(String(describing: agent))")
                    XCTAssertEqual(d.action, action, "\(stderr) / \(String(describing: agent))")
                } else {
                    XCTAssertEqual(d.category, .harnessError, "\(stderr) / \(String(describing: agent))")
                }
            }
        }
    }

    /// Structured error events still count, and the model's own prose still does not.
    func testDiagnosisStillReadsOnlyStructuredErrorEvents() {
        let failed = Data(#"{"type":"turn.failed","error":{"message":"429 Too Many Requests"}}"#.utf8)
        XCTAssertEqual(FailureDiagnosis.classify(exitCode: 1, stdout: failed, stderr: "", parseError: nil, agent: .codex).category,
                       .rateLimited)
        let claude = Data(#"{"type":"result","is_error":true,"result":"Not logged in · Please run /login"}"#.utf8)
        XCTAssertEqual(FailureDiagnosis.classify(exitCode: 1, stdout: claude, stderr: "", parseError: nil, agent: .claude).category,
                       .authExpired)
        let prose = Data(#"{"type":"item.completed","item":{"type":"agent_message","text":"handle the 401 authentication case"}}"#.utf8)
        XCTAssertEqual(FailureDiagnosis.classify(exitCode: 1, stdout: prose, stderr: "", parseError: nil, agent: .codex).category,
                       .harnessError)
    }

    // MARK: - Drift fix: one merged vocabulary

    func testTheMergedVocabularyReachesBothProfiles() {
        for profile in [ClaudeProfile() as any AgentProfile, CodexProfile()] {
            for kind in Self.legacyRateLimitKinds {
                XCTAssertEqual(profile.classify(error: .transcriptAPIError(kind: kind)), .rateLimited, "\(profile.id) \(kind)")
            }
            XCTAssertEqual(profile.classify(error: .transcriptAPIError(kind: "overloaded")), .overloaded)
            XCTAssertEqual(profile.classify(error: .transcriptAPIError(kind: "server_overloaded")), .overloaded)
            XCTAssertEqual(profile.classify(error: .stderr("HTTP 429")), .rateLimited)
            XCTAssertEqual(profile.classify(error: .appServerError(code: nil, message: "Not logged in")), .authExpired)
            XCTAssertNil(profile.classify(error: .transcriptAPIError(kind: "invalid_request")))
            // The transient list is one list now: each CLI's spellings retry for both.
            for kind in Self.legacyCodexTransient.union(Self.legacyClaudeTransient) {
                XCTAssertTrue(profile.isTransient(apiErrorKind: kind), "\(profile.id) \(kind)")
            }
        }
        XCTAssertTrue(CodexTurnRecovery.isTransientKind("overloaded"), "claude's spelling, newly known to codex")
    }

    // MARK: - Environment and the child-session scrub

    func testChildSessionScrubIsOneList() {
        XCTAssertEqual(ClaudeProfile.childSessionVariables, ["CLAUDE_CODE_CHILD_SESSION", "CLAUDECODE"])
        XCTAssertEqual(try HeadlessCommand.build(req(.claude), home: root).unsetEnvironment, ClaudeProfile.childSessionVariables)
        XCTAssertEqual(IndexExtraction.command(prompt: "p", settings: .standard).unsetEnvironment, ClaudeProfile.childSessionVariables)
        XCTAssertEqual(ClaudeProfile.scrubbingChildSession(["A": "1", "CLAUDECODE": "1", "CLAUDE_CODE_CHILD_SESSION": "1"]), ["A": "1"])
    }

    /// The built-in account (nil) builds exactly what `HeadlessCommand.environment` built before.
    func testBuiltInAccountEnvironmentIsUnchanged() throws {
        try write(#"{"env":{"ANTHROPIC_BASE_URL":"http://localhost:8787","PATH":"/settings","CLAUDECODE":"1"}}"#,
                  to: ".claude/settings.json")
        let base = ["PATH": "/usr/bin", "CLAUDE_CODE_CHILD_SESSION": "1", "CLAUDECODE": "1", "KEEP": "k"]
        var legacyClaude = ClaudeUserEnv.merged(into: base, home: root)
        for key in ["CLAUDE_CODE_CHILD_SESSION", "CLAUDECODE"] { legacyClaude.removeValue(forKey: key) }
        let claude = try HeadlessCommand.build(req(.claude), home: root)
        XCTAssertEqual(HeadlessCommand.environment(for: claude, base: base, home: root), legacyClaude)
        XCTAssertEqual(ClaudeProfile(userHome: root).environment(base: base, account: nil), legacyClaude)
        let codex = try HeadlessCommand.build(req(.codex), home: root)
        XCTAssertEqual(HeadlessCommand.environment(for: codex, base: base, home: root), base)
        XCTAssertEqual(CodexProfile(userHome: root).environment(base: base, account: nil), base)
    }

    func testTheEnvironmentIsBuiltPerAccount() throws {
        try write(#"{"env":{"ANTHROPIC_BASE_URL":"http://built-in"}}"#, to: ".claude/settings.json")
        try write(#"{"env":{"ANTHROPIC_BASE_URL":"http://work"}}"#, to: "accounts/work/settings.json")
        let work = AgentAccountRef(id: "work", home: root.appendingPathComponent("accounts/work"))
        let personal = AgentAccountRef(id: "personal", home: root.appendingPathComponent("accounts/personal"))
        let base = ["PATH": "/usr/bin", "CLAUDE_CODE_CHILD_SESSION": "1", "CLAUDE_CONFIG_DIR": "/elsewhere"]

        let claude = try HeadlessCommand.build(req(.claude, account: work), home: root)
        let workEnv = HeadlessCommand.environment(for: claude, base: base, home: root, account: work)
        XCTAssertEqual(workEnv["CLAUDE_CONFIG_DIR"], work.home.path, "the account beats an inherited home")
        XCTAssertEqual(workEnv["ANTHROPIC_BASE_URL"], "http://work", "the account's own settings, not the built-in's")
        XCTAssertNil(workEnv["CLAUDE_CODE_CHILD_SESSION"])
        let personalEnv = HeadlessCommand.environment(for: claude, base: base, home: root, account: personal)
        XCTAssertEqual(personalEnv["CLAUDE_CONFIG_DIR"], personal.home.path)
        XCTAssertNil(personalEnv["ANTHROPIC_BASE_URL"], "an account with no settings file carries none")
        let builtIn = HeadlessCommand.environment(for: claude, base: base, home: root)
        XCTAssertEqual(builtIn["CLAUDE_CONFIG_DIR"], "/elsewhere", "nil leaves the caller's environment alone")
        XCTAssertEqual(builtIn["ANTHROPIC_BASE_URL"], "http://built-in")

        let codex = try HeadlessCommand.build(req(.codex, account: work), home: root)
        XCTAssertEqual(HeadlessCommand.environment(for: codex, base: ["PATH": "/usr/bin"], home: root, account: work),
                       ["PATH": "/usr/bin", "CODEX_HOME": work.home.path])
    }

    func testCodexServiceTierComesFromTheBoundAccountsConfig() throws {
        try write("service_tier = \"fast\"\n", to: ".codex/config.toml")
        try write("service_tier = \"flex\"\n", to: "accounts/work/config.toml")
        let work = AgentAccountRef(id: "work", home: root.appendingPathComponent("accounts/work"))
        let builtIn = try HeadlessCommand.build(req(.codex), home: root).arguments
        XCTAssertTrue(builtIn.contains("service_tier=\"fast\""), "\(builtIn)")
        let bound = try HeadlessCommand.build(req(.codex, account: work), home: root).arguments
        XCTAssertTrue(bound.contains("service_tier=\"flex\""), "\(bound)")
        XCTAssertFalse(bound.contains("service_tier=\"fast\""))
    }

    func testTabsAndSeatsNameTheAccountHomeVariableAlike() {
        XCTAssertEqual(AgentID.claude.homeEnvironmentKey, ClaudeProfile.homeEnvironmentKey)
        XCTAssertEqual(AgentID.codex.homeEnvironmentKey, CodexProfile.homeEnvironmentKey)
        XCTAssertEqual(ClaudeProfile.homeEnvironmentKey, "CLAUDE_CONFIG_DIR")
        XCTAssertEqual(CodexProfile.homeEnvironmentKey, "CODEX_HOME")
    }

    // MARK: - Planning seats bill the project, not the seat (unify brief R9)

    /// A config written before accounts reached planning decodes, and encodes with no `account`
    /// key at all — byte-identical files for everyone who never picked one.
    func testAModelChoiceWithNoAccountCodesAsBefore() throws {
        let old = Data(#"{"harness":"claude","model":"opus","effort":"high"}"#.utf8)
        let decoded = try IntakeJSON.decoder.decode(ModelChoice.self, from: old)
        XCTAssertEqual(decoded, ModelChoice(agent: .claude, model: "opus", effort: "high"))
        XCTAssertFalse(String(decoding: try IntakeJSON.encoder.encode(decoded), as: UTF8.self).contains("account"))
    }

    /// A config saved while the Rounds editor had a per-seat account picker still decodes; the
    /// account it named is ignored (the project decides now) and the next save drops it.
    func testAPerSeatAccountFromAnOldConfigDecodesAndIsDroppedOnSave() throws {
        let old = Data(#"{"harness":"codex","model":"m","effort":"high","account":{"id":"w","home":"file:///accounts/w"}}"#.utf8)
        let decoded = try IntakeJSON.decoder.decode(ModelChoice.self, from: old)
        XCTAssertEqual(decoded, ModelChoice(agent: .codex, model: "m", effort: "high"))
        XCTAssertFalse(String(decoding: try IntakeJSON.encoder.encode(decoded), as: UTF8.self).contains("account"))
        // Inside a whole config too, the shape `intake.json` actually stores.
        let config = PresetExpansion.config(for: .sketch, available: .defaults)!
        var json = String(decoding: try IntakeJSON.encoder.encode(config), as: UTF8.self)
        json = json.replacingOccurrences(of: #""harness":"codex""#, with: #""account":{"id":"w","home":"file:///accounts/w"},"harness":"codex""#)
        XCTAssertTrue(json.contains(#""account""#), "the fixture carries the old key")
        let reread = try IntakeJSON.decoder.decode(RoundConfig.self, from: Data(json.utf8))
        XCTAssertEqual(reread, config)
        XCTAssertFalse(String(decoding: try IntakeJSON.encoder.encode(reread), as: UTF8.self).contains("account"))
    }
}
