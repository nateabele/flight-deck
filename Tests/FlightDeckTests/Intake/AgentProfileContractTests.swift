import XCTest
import IntakeKit
@testable import FlightDeck

/// Track 0 of the grok/gemini planning spec: the `AgentProfile` contract and the two new
/// harness cases. These pin the SAFE behaviour the new cases must have until Tracks G/M land —
/// refused, never offered, never guessed — and the stubs' detectable shape, so each track can
/// tell from a test (not from reading code) whether it has replaced its stub.
final class AgentProfileContractTests: XCTestCase {
    private static let noHome = URL(fileURLWithPath: "/nonexistent-fd-home")

    private func req(_ h: AgentID) -> HeadlessRequest {
        HeadlessRequest(agent: h, model: "m", effort: "high", cwd: URL(fileURLWithPath: "/proj"),
                       readableDirs: [], prompt: "P", schemaFile: URL(fileURLWithPath: "/s.json"),
                       schemaJSON: "{}", resumeSessionID: nil)
    }

    // MARK: Registry

    func testEveryHarnessHasExactlyItsOwnProfile() {
        XCTAssertEqual(AgentProfiles.all.map(\.id), AgentID.planningOrder)
        for agent in AgentID.planningOrder {
            let profile = AgentProfiles.profile(for: agent)
            XCTAssertEqual(profile.id, agent)
            // Gemini runs through Antigravity's `agy` (Track M): the gemini CLI no longer
            // serves Google AI Pro accounts. Every other binary is its harness's raw value.
            XCTAssertEqual(profile.binaryName, agent == .gemini ? "agy" : agent.rawValue)
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
        for agent in AgentID.planningOrder where AgentProfiles.profile(for: agent).hasNativeSchema {
            XCTAssertNil(SchemaRepair.retry(profile: AgentProfiles.profile(for: agent), failure: invalid,
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

    // MARK: AgentID

    func testNewRawValuesRoundTrip() throws {
        XCTAssertEqual(AgentID(rawValue: "grok"), .grok)
        XCTAssertEqual(AgentID(rawValue: "gemini"), .gemini)
        XCTAssertEqual(AgentID.grok.displayName, "Grok")
        XCTAssertEqual(AgentID.gemini.displayName, "Gemini")
        for agent in AgentID.planningOrder {
            let session = HeadlessSession(agent: agent, sessionID: "s", model: "m", effort: "")
            let data = try IntakeJSON.encoder.encode(session)
            XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("\"\(agent.rawValue)\""))
            XCTAssertEqual(try IntakeJSON.decoder.decode(HeadlessSession.self, from: data), session)
        }
    }

    /// An intake written before grok/gemini existed (claude/codex only) still decodes unchanged.
    func testAnIntakeFromBeforeTheNewHarnessesStillDecodes() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(
            forResource: "intake-pre-rounds", withExtension: "json", subdirectory: "Fixtures/Intake"))
        let decoded = try IntakeJSON.decoder.decode(Intake.self, from: Data(contentsOf: url))
        XCTAssertEqual(decoded.triage?.agent, .claude)
        XCTAssertEqual(decoded.triage?.model, "opus")
    }

    /// What `agentHarnessID == nil` used to say — "grok and gemini are not tab or routing
    /// agents" — is `tabReady` now that there is one agent identity (unify brief R4).
    /// gemini became tab-ready with Track M's adapter; grok waits for Track G's.
    func testGrokIsNotTabReadyYet() {
        XCTAssertTrue(AgentID.claude.tabReady)
        XCTAssertTrue(AgentID.codex.tabReady)
        XCTAssertFalse(AgentID.grok.tabReady)
        XCTAssertTrue(AgentID.gemini.tabReady)
        XCTAssertEqual(AgentID.tabReadyCases, [.claude, .codex, .gemini])
    }

    // MARK: Refusal

    // The grok and gemini refusal tests went when both arms landed (Tracks G and M); their
    // argv and parse are pinned by HarnessCommandGrokTests and GeminiHarnessTests.

    /// `account` defaults to nil and changes nothing about the argv.
    func testAccountDefaultsToNilAndLeavesArgvAlone() throws {
        XCTAssertNil(req(.claude).account)
        var bound = req(.claude)
        bound.account = AgentAccountRef(id: "a", home: URL(fileURLWithPath: "/accounts/a"))
        XCTAssertEqual(try HeadlessCommand.build(bound, home: Self.noHome).arguments,
                       try HeadlessCommand.build(req(.claude), home: Self.noHome).arguments)
    }

    func testGenericFallbacksForTheNewHarnesses() {
        let auth = FailureDiagnosis.classify(exitCode: 1, stdout: Data(), stderr: "Unauthorized", parseError: nil, agent: .grok)
        XCTAssertEqual(auth.category, .authExpired)
        XCTAssertEqual(auth.action, "Run `grok login` in a terminal", "grok's sign-in command, probed by Track G")
        let gemini = FailureDiagnosis.classify(exitCode: 1, stdout: Data(), stderr: "Unauthorized", parseError: nil, agent: .gemini)
        XCTAssertEqual(gemini.action, "Run `agy` in a terminal to sign in")

        var parser = ActivityParser(agent: .grok, project: URL(fileURLWithPath: "/proj"), now: { Date(timeIntervalSince1970: 5) })
        parser.feed(Data(#"{"type":"anything","text":"hi"}"#.utf8 + [UInt8(ascii: "\n")]))
        XCTAssertEqual(parser.activity.lastEventAt, Date(timeIntervalSince1970: 5))
        XCTAssertNil(parser.activity.error)
    }

    // MARK: Availability

    /// grok and gemini are offered only once their track adds them to `headlessReady`.
    func testAvailabilityFollowsTheGate() {
        let grok = ModelChoice(agent: .grok, model: "grok-4.6", effort: "high")
        let gemini = ModelChoice(agent: .gemini, model: "pro", effort: "")
        let claude = ModelChoice(agent: .claude, model: "opus", effort: "high")
        let available = AvailableModels(choices: [.grok: grok, .gemini: gemini, .claude: claude])
        // Each new harness is offered exactly when its track has opened the gate for it.
        let expected = AgentID.planningOrder.filter { $0 != .codex && AgentProfiles.headlessReady.contains($0) }
        XCTAssertEqual(available.agents, expected)
        XCTAssertEqual(available.choice(for: .grok), AgentProfiles.headlessReady.contains(.grok) ? grok : nil)
        XCTAssertEqual(available.choice(for: .gemini), AgentProfiles.headlessReady.contains(.gemini) ? gemini : nil)
        XCTAssertEqual(RoundConfigEditor.agents(in: available), expected)
        XCTAssertEqual(RoundConfigEditor.agents(in: .defaults), [.codex, .claude])
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
        // grok IS probed once its gate is open; a probe that can't answer reads as signed out,
        // so it is not offered either way.
        let available = TriageSettings.available(path: bin.path, probe: SignInProbe { executable, _, _ in
            XCTAssertEqual((executable as NSString).lastPathComponent, "grok", "no agy installed, so no gemini probe")
            return nil
        })
        XCTAssertEqual(available.agents, [.codex, .claude])
    }
}
