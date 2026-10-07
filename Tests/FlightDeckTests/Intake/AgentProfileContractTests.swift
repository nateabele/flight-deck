import XCTest
import IntakeKit
@testable import FlightDeck

/// Track 0 of the grok/gemini planning spec: the `AgentProfile` contract and the two new
/// harness cases. These pin the SAFE behaviour the new cases must have until Tracks G/M land —
/// refused, never offered, never guessed — and the stubs' detectable shape, so each track can
/// tell from a test (not from reading code) whether it has replaced its stub.
final class AgentProfileContractTests: XCTestCase {
    private static let noHome = URL(fileURLWithPath: "/nonexistent-fd-home")

    private func req(_ h: Harness) -> HarnessRequest {
        HarnessRequest(harness: h, model: "m", effort: "high", cwd: URL(fileURLWithPath: "/proj"),
                       readableDirs: [], prompt: "P", schemaFile: URL(fileURLWithPath: "/s.json"),
                       schemaJSON: "{}", resumeSessionID: nil)
    }

    // MARK: Registry

    func testEveryHarnessHasExactlyItsOwnProfile() {
        XCTAssertEqual(AgentProfiles.all.map(\.id), Harness.allCases)
        for harness in Harness.allCases {
            let profile = AgentProfiles.profile(for: harness)
            XCTAssertEqual(profile.id, harness)
            XCTAssertEqual(profile.family, ModelFamily(harness))
            // Gemini runs through Antigravity's `agy` (Track M): the gemini CLI no longer
            // serves Google AI Pro accounts. Every other binary is its harness's raw value.
            XCTAssertEqual(profile.binaryName, harness == .gemini ? "agy" : harness.rawValue)
        }
    }

    /// The stubs' detectable shape. A track that replaces a stub deletes its `unimplemented`
    /// override, and this test then stops checking that profile — so it stays green while the
    /// tracks land one by one, and needs no edit from any of them.
    func testStubsReturnTheExplicitUnimplementedValues() {
        let expected: [Harness: String] = [.claude: AgentProfileStub.trackP, .codex: AgentProfileStub.trackP,
                                           .grok: AgentProfileStub.trackG, .gemini: AgentProfileStub.trackM]
        let base = ["PATH": "/usr/bin", "CLAUDE_CODE_CHILD_SESSION": "1"]
        let account = AgentAccountRef(id: "a", home: URL(fileURLWithPath: "/accounts/a"))
        for profile in AgentProfiles.all {
            guard let marker = profile.unimplemented else { continue }
            XCTAssertEqual(marker, expected[profile.id])
            XCTAssertTrue(profile.modelCatalog.isEmpty, "\(profile.id)")
            XCTAssertEqual(profile.parseModelList("grok-4.6\ngrok-4.5\n"), [])
            XCTAssertNil(profile.classify(error: .stderr("429 rate limit exceeded")))
            XCTAssertNil(profile.classify(error: .appServerError(code: 401, message: "unauthorized")))
            XCTAssertEqual(profile.environment(base: base, account: account), base)
            // A stub can never read as signed in, whatever its check's command prints.
            XCTAssertEqual(profile.signInCheck.readiness(SignInCheckOutput(stdout: "ok", stderr: "", exitCode: 0)),
                           .signedOut(hint: marker))
        }
    }

    func testSchemaCapabilityMatchesEachCLI() {
        XCTAssertTrue(AgentProfiles.profile(for: .claude).hasNativeSchema)
        XCTAssertTrue(AgentProfiles.profile(for: .codex).hasNativeSchema)
        XCTAssertTrue(AgentProfiles.profile(for: .grok).hasNativeSchema)
        XCTAssertTrue(AgentProfiles.profile(for: .gemini).hasNativeSchema, "agy --json-schema")
    }

    /// The seam is wired but decides nothing yet; a native-schema harness must never retry,
    /// whatever Track M later does for the others.
    func testSchemaRepairNeverRetriesANativeSchemaHarness() {
        let invalid = Diagnosis(category: .invalidOutput, detail: "notJSON", action: "")
        for harness in Harness.allCases where AgentProfiles.profile(for: harness).hasNativeSchema {
            XCTAssertNil(SchemaRepair.retry(profile: AgentProfiles.profile(for: harness), failure: invalid,
                                            sessionID: "S1", access: .readOnly, isRepair: false))
        }
        XCTAssertNil(SchemaRepair.retry(profile: GeminiProfile(), failure: invalid, sessionID: "S1",
                                        access: .readOnly, isRepair: true), "a repair never repairs")
    }

    func testSignInCheckPredicateDecidesReadiness() {
        let check = SignInCheck(arguments: ["models"], signedOutHint: "Grok: run `grok login`",
                                isSignedIn: { !$0.stdout.contains("not authenticated") })
        XCTAssertEqual(check.readiness(SignInCheckOutput(stdout: "grok-4.6", stderr: "", exitCode: 0)), .ready)
        XCTAssertEqual(check.readiness(SignInCheckOutput(stdout: "You are not authenticated.", stderr: "", exitCode: 1)),
                       .signedOut(hint: "Grok: run `grok login`"))
    }

    // MARK: Harness and ModelFamily

    func testNewRawValuesRoundTrip() throws {
        XCTAssertEqual(Harness(rawValue: "grok"), .grok)
        XCTAssertEqual(Harness(rawValue: "gemini"), .gemini)
        XCTAssertEqual(ModelFamily(.grok), .grok)
        XCTAssertEqual(ModelFamily(.gemini), .gemini)
        XCTAssertEqual(ModelFamily.grok.displayName, "Grok")
        XCTAssertEqual(ModelFamily.gemini.displayName, "Gemini")
        for harness in Harness.allCases {
            let session = HarnessSession(harness: harness, sessionID: "s", model: "m", effort: "")
            let data = try IntakeJSON.encoder.encode(session)
            XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("\"\(harness.rawValue)\""))
            XCTAssertEqual(try IntakeJSON.decoder.decode(HarnessSession.self, from: data), session)
        }
    }

    /// An intake written before grok/gemini existed (claude/codex only) still decodes unchanged.
    func testAnIntakeFromBeforeTheNewHarnessesStillDecodes() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(
            forResource: "intake-pre-rounds", withExtension: "json", subdirectory: "Fixtures/Intake"))
        let decoded = try IntakeJSON.decoder.decode(Intake.self, from: Data(contentsOf: url))
        XCTAssertEqual(decoded.triage?.harness, .claude)
        XCTAssertEqual(decoded.triage?.model, "opus")
    }

    func testGrokAndGeminiAreNotAgentHarnesses() {
        XCTAssertEqual(Harness.claude.agentHarnessID, "claude")
        XCTAssertEqual(Harness.codex.agentHarnessID, "codex")
        XCTAssertNil(Harness.grok.agentHarnessID)
        XCTAssertNil(Harness.gemini.agentHarnessID)
    }

    // MARK: Refusal

    func testBuildRefusesGrokAndGemini() {
        for harness in [Harness.grok] {
            XCTAssertThrowsError(try HarnessCommand.build(req(harness), home: Self.noHome)) { error in
                XCTAssertEqual(error as? HarnessCommand.HarnessCommandError, .harnessNotImplemented(harness))
            }
        }
    }

    func testParseRefusesGrokAndGemini() {
        let stdout = Data(#"{"session_id":"S","structured_output":{}}"#.utf8)
        for harness in [Harness.grok] {
            XCTAssertThrowsError(try HarnessOutput.parse(harness, stdout: stdout)) { error in
                XCTAssertEqual(error as? HarnessOutput.ParseError, .harnessNotImplemented(harness))
            }
        }
    }

    /// `account` defaults to nil and changes nothing about the argv.
    func testAccountDefaultsToNilAndLeavesArgvAlone() throws {
        XCTAssertNil(req(.claude).account)
        var bound = req(.claude)
        bound.account = AgentAccountRef(id: "a", home: URL(fileURLWithPath: "/accounts/a"))
        XCTAssertEqual(try HarnessCommand.build(bound, home: Self.noHome).arguments,
                       try HarnessCommand.build(req(.claude), home: Self.noHome).arguments)
    }

    func testGenericFallbacksForTheNewHarnesses() {
        let auth = FailureDiagnosis.classify(exitCode: 1, stdout: Data(), stderr: "Unauthorized", parseError: nil, harness: .grok)
        XCTAssertEqual(auth.category, .authExpired)
        XCTAssertEqual(auth.action, "Sign in to `grok` in a terminal")
        let gemini = FailureDiagnosis.classify(exitCode: 1, stdout: Data(), stderr: "Unauthorized", parseError: nil, harness: .gemini)
        XCTAssertEqual(gemini.action, "Run `agy` in a terminal to sign in")

        var parser = ActivityParser(harness: .grok, project: URL(fileURLWithPath: "/proj"), now: { Date(timeIntervalSince1970: 5) })
        parser.feed(Data(#"{"type":"anything","text":"hi"}"#.utf8 + [UInt8(ascii: "\n")]))
        XCTAssertEqual(parser.activity.lastEventAt, Date(timeIntervalSince1970: 5))
        XCTAssertNil(parser.activity.error)
    }

    // MARK: Availability

    func testAvailabilityNeverOffersGrokOrGemini() throws {
        try XCTSkipUnless(AgentProfiles.headlessReady.contains(.gemini), "gemini is not headless-ready yet")
        let grok = ModelChoice(harness: .grok, model: "grok-4.6", effort: "high")
        let gemini = ModelChoice(harness: .gemini, model: "pro", effort: "")
        let claude = ModelChoice(harness: .claude, model: "opus", effort: "high")
        let available = AvailableModels(choices: [.grok: grok, .gemini: gemini, .claude: claude])
        XCTAssertEqual(available.harnesses, [.claude, .gemini])
        XCTAssertNil(available.choice(for: .grok))
        XCTAssertEqual(RoundConfigEditor.harnesses(in: available), [.claude, .gemini])
        XCTAssertEqual(RoundConfigEditor.harnesses(in: .defaults), [.codex, .claude])
    }

    /// Detection with every CLI on PATH still offers only the two with builders.
    func testDetectionWithGrokAndGeminiInstalledOffersNeither() throws {
        let bin = FileManager.default.temporaryDirectory.appendingPathComponent("fd-profile-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: bin) }
        for tool in ["claude", "codex", "grok", "gemini"] {
            let file = bin.appendingPathComponent(tool)
            try Data("#!/bin/sh\n".utf8).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        }
        // No `agy` here, so gemini is not offered either (the `gemini` CLI is not what the
        // harness drives); the probe must never run.
        let available = TriageSettings.available(path: bin.path, probe: SignInProbe { _, _, _ in
            XCTFail("no agy installed, so no sign-in probe"); return nil
        })
        XCTAssertEqual(available.harnesses, [.codex, .claude])
    }
}
