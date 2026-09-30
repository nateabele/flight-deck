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
