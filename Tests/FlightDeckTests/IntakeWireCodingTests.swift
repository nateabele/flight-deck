import XCTest
@testable import FleetKit
@testable import FlightDeck

final class IntakeWireCodingTests: XCTestCase {
    static let summary = WireIntakeSummary(
        id: UUID(), title: "Offline sync for job tickets", state: "shaping",
        needsAttention: false, preset: "fullPlan", now: "Refine 2", runStatus: "running",
        clockSince: Date(timeIntervalSinceReferenceDate: 800_000_000),
        agentsDone: 1, agentsTotal: 2, createdAt: Date(timeIntervalSinceReferenceDate: 799_000_000)
    )

    func testProjectIntakesRoundTripsWithItsDottedTag() throws {
        let event = FleetEvent.projectIntakes(project: UUID(), intakes: [Self.summary])
        let data = try JSONEncoder().encode(event)
        XCTAssertEqual(try JSONDecoder().decode(FleetEvent.self, from: data), event)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(json.contains("\"project.intakes\""), json)
    }

    func testProjectIntakesWithNilOmitsTheKey() throws {
        // nil = Flight Control not enabled for the project: absent, never `null`, so the
        // phone's `decodeIfPresent` reads exactly what an older Mac would send.
        let data = try JSONEncoder().encode(FleetEvent.projectIntakes(project: UUID(), intakes: nil))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(json["intakes"])
        XCTAssertEqual(try JSONDecoder().decode(FleetEvent.self, from: data),
                       .projectIntakes(project: try XCTUnwrap(UUID(uuidString: json["project"] as! String)), intakes: nil))
    }

    func testProjectIntakesNamesItsProjectAndNoSession() {
        let project = UUID()
        let event = FleetEvent.projectIntakes(project: project, intakes: [])
        XCTAssertEqual(event.projectID, project)
        XCTAssertNil(event.sessionID)
    }

    func testProjectIntakesReplacesTheProjectsListOnTheSnapshot() {
        let project = WireProject(id: UUID(), name: "larkOS", path: "/w/larkOS")
        var snapshot = FleetSnapshot(projects: [project])
        snapshot.apply(.projectIntakes(project: project.id, intakes: [Self.summary]))
        XCTAssertEqual(snapshot.projects[0].intakes, [Self.summary])
        snapshot.apply(.projectIntakes(project: project.id, intakes: nil))
        XCTAssertNil(snapshot.projects[0].intakes)
        // An unknown project is ignored, like every other project event.
        let before = snapshot
        snapshot.apply(.projectIntakes(project: UUID(), intakes: []))
        XCTAssertEqual(snapshot, before)
    }

    func testAProjectFromAnOlderMacDecodesWithNoIntakes() throws {
        let old = #"{"id":"\#(UUID().uuidString)","name":"a","path":"/a","isCollapsed":false,"sessions":[]}"#
        let project = try JSONDecoder().decode(WireProject.self, from: Data(old.utf8))
        XCTAssertNil(project.intakes)
    }

    func testAnUnknownStateStringStillDecodes() throws {
        var summary = Self.summary
        summary.state = "someFutureState"
        let data = try JSONEncoder().encode(summary)
        XCTAssertEqual(try JSONDecoder().decode(WireIntakeSummary.self, from: data).state, "someFutureState")
    }

    func testThePhoneAdvertisesFlightControl() {
        XCTAssertEqual(FleetCapability.flightControl, "flightControl")
        XCTAssertTrue(FleetCapability.supported.contains(FleetCapability.flightControl))
    }

    /// A note names the version it was written on; a Mac that predates that sends neither key,
    /// and the phone still decodes the note (as one with no version).
    func testANoteRoundTripsItsVersionAndDecodesWithout() throws {
        let id = UUID()
        let pinned = WireNote(id: id, kind: "comment", text: "Why not SQLite?", quote: "Run PostgreSQL", section: "## Storage",
                              consumed: true, blockIndex: nil, checkpoint: 1, version: "Draft · Round 0")
        let data = try JSONEncoder().encode(pinned)
        XCTAssertEqual(try JSONDecoder().decode(WireNote.self, from: data), pinned)

        let old = Data(#"{"id":"\#(id.uuidString)","kind":"comment","text":"Why not SQLite?","quote":"Run PostgreSQL","consumed":true}"#.utf8)
        let decoded = try JSONDecoder().decode(WireNote.self, from: old)
        XCTAssertNil(decoded.checkpoint)
        XCTAssertNil(decoded.version)
        XCTAssertEqual(decoded.quote, "Run PostgreSQL")
        XCTAssertEqual(decoded.id, id)
    }

    func testADetailRoundTripsEveryNestedType() throws {
        let note = WireNote(id: UUID(), kind: "mustChange", text: "Not enough.",
                            quote: "Require explicit proof", section: "7. Model-credential paths",
                            consumed: false, blockIndex: 14)
        let detail = WireIntakeDetail(
            etag: "abc", project: UUID(), summary: Self.summary, intent: "Build it.",
            progress: [WireProgressPhase(label: "Triage", detail: "3:40")],
            board: WireBoard(
                slots: [WireSlot(id: "refine-2", name: "Refine 2", code: "RF2", state: "live",
                                 major: false, group: "REFINE", checkpoint: nil, duration: nil, flagged: false)],
                nowName: "Refine 2", nowChip: "ON COURSE", clockCaption: "IN THE AIR",
                clockSince: Self.summary.clockSince, clockText: nil, stopsAt: "Encode",
                stopSlotID: "encode-0", callingAt: "2 · Polish 6 · Review",
                convergence: WireConvergence(word: "CONVERGING ↘", amber: false, spark: [41, 14]),
                defaultPlay: "nextMajor"),
            agents: [WireAgent(id: "refine-2-reviewer", glyph: "running", role: "reviewer",
                               identity: "codex · gpt-6-sol · high", headline: "Checking §7",
                               action: "Reading broker.ts", footprint: [WireFootprint(dir: "beacon", count: 3)],
                               startedAt: Self.summary.clockSince)],
            rounds: [WireRound(checkpoint: 3, name: "Refine 1", code: "RF1", stage: "refine",
                               startedAt: nil, landedAt: Date(timeIntervalSinceReferenceDate: 800_000_100),
                               outcome: "ok", changeCount: 41, linesAdded: 620, linesRemoved: 180,
                               verdicts: WireVerdicts(agreed: 33, somewhat: 6, declined: 2), note: nil,
                               sectionsChanged: ["7. Model-credential paths"],
                               agents: [WireRoundAgent(role: "reviewer", ran: "codex · gpt-6-sol · high", status: "ok", detail: nil)],
                               notesConsumed: [note])],
            questions: WireQuestions(open: nil, answered: [WireExchange(questions: ["Both?"], answers: ["Both"])]),
            choice: nil, failure: nil, pendingNotes: 1, halt: nil, headCheckpoint: 3,
            servedAt: Date(timeIntervalSinceReferenceDate: 800_000_200))
        let data = try JSONEncoder().encode(detail)
        XCTAssertEqual(try JSONDecoder().decode(WireIntakeDetail.self, from: data), detail)
    }

    // MARK: phone fidelity + round inspector

    static let seat = WireSeat(
        choice: WireModelChoice(agent: "codex", agentName: "Codex", model: "gpt-6-sol", effort: "high"),
        persona: "arbiter",
        fallback: WireModelChoice(agent: "claude", agentName: "Claude", model: "opus", effort: "high"))

    static let config = WireRoundConfig(
        drafters: [seat], synthesizer: seat, reviewer: seat, crossReviewer: seat, crossCheck: "firstAndLast",
        integrator: seat, encoder: seat, polisher: seat, refinementCap: 3, polishCap: 2,
        freshEyesAndDedup: true, defaultPlay: "nextMajor", customized: true)

    func testARoundConfigAndTheChoosersPresetsRoundTrip() throws {
        let detail = WireIntakeDetail(
            etag: "abc", project: UUID(), summary: Self.summary, intent: "Build it.",
            choice: WireChoice(recommended: "featurePlan", reason: "Touches three modules.",
                               presets: [WirePresetOption(preset: "bead"),
                                         WirePresetOption(preset: "featurePlan", config: Self.config)]),
            servedAt: Date(timeIntervalSinceReferenceDate: 800_000_200), steer: true, choose: true,
            roundConfig: Self.config)
        let data = try JSONEncoder().encode(detail)
        XCTAssertEqual(try JSONDecoder().decode(WireIntakeDetail.self, from: data), detail)
    }

    /// The rotations are additive: they round-trip, and a config from a Mac that predates them (no
    /// keys at all) decodes with none, which the phone reads as one agent per role.
    func testRotationsRoundTripAndAnOldConfigDecodesWithoutThem() throws {
        var rotating = Self.config
        rotating.reviewers = [Self.seat, Self.seat]
        rotating.integrators = [Self.seat, Self.seat]
        rotating.polishers = [Self.seat, Self.seat, Self.seat]
        let data = try JSONEncoder().encode(rotating)
        XCTAssertEqual(try JSONDecoder().decode(WireRoundConfig.self, from: data), rotating)

        let plain = try JSONSerialization.jsonObject(with: JSONEncoder().encode(Self.config)) as? [String: Any]
        for key in ["reviewers", "integrators", "polishers"] { XCTAssertNil(plain?[key], key) }
        let old = try JSONDecoder().decode(WireRoundConfig.self, from: JSONEncoder().encode(Self.config))
        XCTAssertNil(old.reviewers); XCTAssertNil(old.integrators); XCTAssertNil(old.polishers)

        // An older phone's decoder skips the keys it does not know.
        struct OldConfig: Codable { var drafters: [WireSeat]; var integrator: WireSeat; var polisher: WireSeat? }
        let older = try JSONDecoder().decode(OldConfig.self, from: data)
        XCTAssertEqual(older.integrator, Self.seat)
    }

    static let menu = WireRoundsMenu(agents: [
        WireAgentOption(
            agent: "claude", name: "Claude",
            models: [WireModelOption(id: "opus", name: "Opus 5.5", efforts: ["low", "high"]), WireModelOption(id: "haiku", name: "Haiku 4.5")],
            accountModels: ["account:1": [WireModelOption(id: "opus", name: "Opus 5.5", efforts: ["high"])]],
            efforts: ["low", "high"], planningEffort: "high",
            defaultChoice: WireModelChoice(agent: "claude", agentName: "Claude", model: "opus", effort: "high"),
            accounts: WireAccountMenu(defaultTitle: "Project default — Personal", offersChoice: true,
                                      options: [WireAccountOption(key: "account:1", title: "Work"),
                                                WireAccountOption(key: "pool:team", title: "Team pool", isPool: true)])),
        WireAgentOption(agent: "grok", name: "Grok", reason: "Grok: run `grok login`"),
    ])

    /// The editor's wire is additive: it round-trips, and a detail from a Mac that predates it
    /// (no key at all) decodes with none, which the phone reads as a read-only inspector.
    func testTheEditorsMenuAndLockRoundTripAndAnOlderDetailDecodesWithoutThem() throws {
        var detail = WireIntakeDetail(
            etag: "abc", project: UUID(), summary: Self.summary, intent: "Build it.",
            servedAt: Date(timeIntervalSinceReferenceDate: 800_000_200), steer: true, choose: true,
            roundConfig: Self.config, editRounds: true, roundsMenu: Self.menu,
            roundsLock: WireRoundsLock(editable: false, reason: "Pause to change agents.", locked: ["drafter0", "reviewer"],
                                       refineDone: true, extraRefinement: 1, refinementFloor: 2))
        XCTAssertEqual(try JSONDecoder().decode(WireIntakeDetail.self, from: JSONEncoder().encode(detail)), detail)

        detail.editRounds = nil; detail.roundsMenu = nil; detail.roundsLock = nil
        let data = try JSONEncoder().encode(detail)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        for key in ["editRounds", "roundsMenu", "roundsLock"] { XCTAssertNil(json[key], key) }
        let old = try JSONDecoder().decode(WireIntakeDetail.self, from: data)
        XCTAssertNil(old.editRounds); XCTAssertNil(old.roundsMenu); XCTAssertNil(old.roundsLock)
        XCTAssertEqual(old.roundConfig, Self.config)
    }

    /// An older phone skips every key it does not know, so a newer Mac's payload decodes there.
    func testANewerDetailStillDecodesAsThePhoneBeforeTheEditor() throws {
        struct OldDetail: Codable { var etag: String; var steer: Bool?; var choose: Bool?; var roundConfig: WireRoundConfig? }
        let detail = WireIntakeDetail(
            etag: "abc", project: UUID(), summary: Self.summary, intent: "i", servedAt: Date(), steer: true, choose: true,
            roundConfig: Self.config, editRounds: true, roundsMenu: Self.menu, roundsLock: WireRoundsLock(editable: true))
        let old = try JSONDecoder().decode(OldDetail.self, from: JSONEncoder().encode(detail))
        XCTAssertEqual(old.roundConfig, Self.config)
    }

    func testAnAccountTravelsAsANameAndAKeyAndAnOldChoiceHasNoKey() throws {
        let choice = WireModelChoice(agent: "claude", agentName: "Claude", model: "opus", effort: "high", modelName: "Opus 5.5",
                                     account: "Team pool", accountKey: "pool:team")
        XCTAssertEqual(try JSONDecoder().decode(WireModelChoice.self, from: JSONEncoder().encode(choice)), choice)
        let plain = try JSONSerialization.jsonObject(with: JSONEncoder().encode(
            WireModelChoice(agent: "claude", model: "opus", effort: "high"))) as? [String: Any]
        XCTAssertNil(plain?["accountKey"])
        let old = try JSONDecoder().decode(WireModelChoice.self, from: Data(#"{"agent":"claude","model":"opus","effort":"high"}"#.utf8))
        XCTAssertNil(old.accountKey)
    }

    func testChooseIsAdditiveAnOlderPayloadDecodesWithoutIt() throws {
        // A detail from a Mac that predates the chooser and the inspector: none of the new keys.
        let detail = WireIntakeDetail(
            etag: "abc", project: UUID(), summary: Self.summary, intent: "Build it.",
            choice: WireChoice(recommended: "sketch", reason: "Small."),
            servedAt: Date(timeIntervalSinceReferenceDate: 800_000_200), steer: true)
        let data = try JSONEncoder().encode(detail)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(json["choose"])
        XCTAssertNil(json["roundConfig"])
        XCTAssertNil((json["choice"] as? [String: Any])?["presets"])
        let decoded = try JSONDecoder().decode(WireIntakeDetail.self, from: data)
        XCTAssertNil(decoded.choose)
        XCTAssertNil(decoded.roundConfig)
        XCTAssertNil(decoded.choice?.presets)
    }

    /// An older phone's decoder ignores keys it does not know, so a newer Mac's payload still
    /// decodes there: simulated by decoding the pre-chooser shape of `WireChoice` from the new JSON.
    func testANewerPayloadStillDecodesAsTheOlderChoiceShape() throws {
        struct OldChoice: Codable { var recommended: String?; var reason: String?; var chosen: String?; var roundsSummary: String? }
        let new = WireChoice(recommended: "sketch", presets: [WirePresetOption(preset: "sketch", config: Self.config)])
        let old = try JSONDecoder().decode(OldChoice.self, from: JSONEncoder().encode(new))
        XCTAssertEqual(old.recommended, "sketch")
    }

    func testAConfigFromAMacWithNewerWordsStillDecodes() throws {
        // Policy, play mode and persona are strings, never enums: a value added later must not throw.
        var config = Self.config
        config.crossCheck = "someNewPolicy"
        config.defaultPlay = "someNewPlay"
        let data = try JSONEncoder().encode(config)
        XCTAssertEqual(try JSONDecoder().decode(WireRoundConfig.self, from: data).crossCheck, "someNewPolicy")
    }

    func testABoardRoundTripsItsControls() throws {
        let board = WireBoard(
            nowName: "Refine 2", nowChip: "PAUSED", clockCaption: "PAUSED FOR", stopsAt: "Encode",
            callingAt: "Review", defaultPlay: "nextMajor",
            controls: WireControls(enabled: ["step", "nextMajor", "toReview", "extend", "trim"],
                                   extendStage: "refine", trimStage: "refine", cycleName: "Refine", cyclePlanned: 3))
        let data = try JSONEncoder().encode(board)
        XCTAssertEqual(try JSONDecoder().decode(WireBoard.self, from: data), board)
    }

    /// A Phase-1 Mac sends neither field: the phone must read "no steering" (nil), never fail
    /// to decode the detail it already knows how to show.
    func testADetailFromAPhase1MacDecodesWithNoSteer() throws {
        let detail = WireIntakeDetail(
            etag: "abc", project: UUID(), summary: Self.summary, intent: "Build it.",
            board: WireBoard(nowName: "Refine 2", nowChip: "ON COURSE", clockCaption: "IN THE AIR",
                             stopsAt: "Encode", callingAt: "Review", defaultPlay: "nextMajor"),
            servedAt: Date(timeIntervalSinceReferenceDate: 800_000_200))
        let data = try JSONEncoder().encode(detail)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(json.contains("\"steer\""), json)
        XCTAssertFalse(json.contains("\"controls\""), json)
        let decoded = try JSONDecoder().decode(WireIntakeDetail.self, from: data)
        XCTAssertNil(decoded.steer)
        XCTAssertNil(decoded.board?.controls)
        XCTAssertEqual(decoded, detail)
    }

    func testAPlanRoundTrips() throws {
        let plan = WireIntakePlan(
            checkpoint: 3, roundName: "Refine 1", editsVersion: "", markdown: "# P\n\n## 1. A\n\nText.",
            outline: [WireSection(heading: "1. A", level: 2, blockIndex: 1, churn: [4, 0],
                                  diverging: false, settledSince: "Refine 1")],
            notes: [], added: [2], removed: [WireRemovedBlock(after: 1, text: "Old text.")])
        let data = try JSONEncoder().encode(plan)
        XCTAssertEqual(try JSONDecoder().decode(WireIntakePlan.self, from: data), plan)
    }

    func testActivityThresholdsMatchTheDesktop() {
        XCTAssertEqual(AgentActivityRules.quiet, 30)
        XCTAssertEqual(AgentActivityRules.stalled, 90)
    }

    func testTheDesktopRowsUseTheSharedThresholds() {
        XCTAssertEqual(SeatThresholds.default.quiet, AgentActivityRules.quiet)
        XCTAssertEqual(SeatThresholds.default.stalled, AgentActivityRules.stalled)
    }
}
