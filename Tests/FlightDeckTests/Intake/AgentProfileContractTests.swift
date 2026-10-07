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

    /// Every shipped profile is real: Tracks P, G and M each replaced their Track 0 stub, and
    /// the stub markers were deleted with the last of them. A placeholder that slipped back in
    /// would offer an empty catalog and a sign-in check that never passes.
    func testNoProfileIsAStub() {
        for profile in AgentProfiles.all {
            XCTAssertNil(profile.unimplemented, "\(profile.id)")
            XCTAssertFalse(profile.modelCatalog.isEmpty, "\(profile.id)")
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

    // The grok and gemini refusal tests went when both arms landed (Tracks G and M); their
    // argv and parse are pinned by HarnessCommandGrokTests and GeminiHarnessTests.

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
        XCTAssertEqual(auth.action, "Run `grok login` in a terminal", "grok's sign-in command, probed by Track G")
        let gemini = FailureDiagnosis.classify(exitCode: 1, stdout: Data(), stderr: "Unauthorized", parseError: nil, harness: .gemini)
        XCTAssertEqual(gemini.action, "Run `agy` in a terminal to sign in")

        var parser = ActivityParser(harness: .grok, project: URL(fileURLWithPath: "/proj"), now: { Date(timeIntervalSince1970: 5) })
        parser.feed(Data(#"{"type":"anything","text":"hi"}"#.utf8 + [UInt8(ascii: "\n")]))
        XCTAssertEqual(parser.activity.lastEventAt, Date(timeIntervalSince1970: 5))
        XCTAssertNil(parser.activity.error)
    }

    // MARK: Availability

    /// grok and gemini are offered only once their track adds them to `headlessReady`.
    func testAvailabilityFollowsTheGate() {
        let grok = ModelChoice(harness: .grok, model: "grok-4.6", effort: "high")
        let gemini = ModelChoice(harness: .gemini, model: "pro", effort: "")
        let claude = ModelChoice(harness: .claude, model: "opus", effort: "high")
        let available = AvailableModels(choices: [.grok: grok, .gemini: gemini, .claude: claude])
        // Each new harness is offered exactly when its track has opened the gate for it.
        let expected = Harness.allCases.filter { $0 != .codex && AgentProfiles.headlessReady.contains($0) }
        XCTAssertEqual(available.harnesses, expected)
        XCTAssertEqual(available.choice(for: .grok), AgentProfiles.headlessReady.contains(.grok) ? grok : nil)
        XCTAssertEqual(available.choice(for: .gemini), AgentProfiles.headlessReady.contains(.gemini) ? gemini : nil)
        XCTAssertEqual(RoundConfigEditor.harnesses(in: available), expected)
        XCTAssertEqual(RoundConfigEditor.harnesses(in: .defaults), [.codex, .claude])
    }

    /// Detection with every CLI on PATH offers neither newcomer when they can't prove a sign-in:
    /// these stub scripts print nothing, so grok's check reads signed out, and gemini has no
    /// builder at all.
    func testDetectionWithStubGrokAndGeminiOffersNeither() throws {
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
