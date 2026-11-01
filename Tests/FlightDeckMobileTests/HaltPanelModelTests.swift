import FleetKit
import XCTest
@testable import FlightDeckMobile

@MainActor
private final class RetryCommander: IntakeCommanding {
    private(set) var commands: [FleetCommand] = []
    private var pending: [(Result<Void, FleetRequestError>) -> Void] = []
    func sendIntake(_ command: FleetCommand, then: @escaping (Result<Void, FleetRequestError>) -> Void) {
        commands.append(command); pending.append(then)
    }
    func answer(_ result: Result<Void, FleetRequestError>) { pending.removeFirst()(result) }
}

@MainActor
final class HaltPanelModelTests: XCTestCase {
    private var seat: WireSeat {
        WireSeat(choice: WireModelChoice(agent: "claude", agentName: "Claude", model: "opus", effort: "high", modelName: "Opus"))
    }

    private var config: WireRoundConfig {
        WireRoundConfig(drafters: [seat], synthesizer: seat, reviewer: seat, integrator: seat, encoder: seat,
                        polisher: seat, refinementCap: 3, polishCap: 2, freshEyesAndDedup: false,
                        defaultPlay: "nextMajor", customized: false)
    }

    private func halt(_ kind: String = "roundFailed", actions: [String], output: String? = "boom\nline2",
                      slot: WireHaltSlot? = WireHaltSlot(role: "polisher", ran: "Gemini 3 Pro · high", stage: "polish", slotIndex: 0),
                      since: Date? = Date(timeIntervalSinceReferenceDate: 100)) -> WireHalt {
        WireHalt(kind: kind, title: "Polish 5 failed", reason: "Harness error", whatToDo: "Try another model.",
                 since: since, slot: slot, output: output, actions: actions)
    }

    private func detail(_ halt: WireHalt?, retry: Bool? = true, steer: Bool? = true, editable: Bool = true) -> WireIntakeDetail {
        WireIntakeDetail(
            etag: "e", project: UUID(),
            summary: WireIntakeSummary(id: UUID(), title: "t", state: "shaping", needsAttention: false, createdAt: Date()),
            intent: "i",
            board: WireBoard(nowName: "Polish 5", nowChip: "", clockCaption: "", stopsAt: "", callingAt: "", defaultPlay: "nextMajor"),
            servedAt: Date(), steer: steer, roundConfig: config, editRounds: editable,
            roundsMenu: WireRoundsMenu(agents: [WireAgentOption(agent: "claude", name: "Claude")]),
            roundsLock: WireRoundsLock(editable: true), halted: halt, retry: retry)
    }

    private func make(_ d: WireIntakeDetail, inFlight: Set<IntakeAction> = [], live: Bool = true) -> HaltPanelModel? {
        HaltPanelModel.make(detail: d, inFlight: inFlight, live: live)
    }

    func testNothingHaltedMeansNoPanel() {
        XCTAssertNil(make(detail(nil)))
    }

    func testButtonsFollowTheMacsActionsInOrder() throws {
        let m = try XCTUnwrap(make(detail(halt(actions: ["retry", "retryOther", "showOutput", "toReview"]))))
        XCTAssertEqual(m.buttons.map(\.action), [.retry, .retryOther, .toReview])
        XCTAssertEqual(m.buttons.map(\.title), ["Retry", "Retry with another model", "To review"])
        XCTAssertTrue(m.isFailure)
    }

    func testPausedOffersResumeAndIsNotAFailure() throws {
        let m = try XCTUnwrap(make(detail(halt("paused", actions: ["resume", "toReview"], output: nil, slot: nil))))
        XCTAssertEqual(m.buttons.map(\.action), [.resume, .toReview])
        XCTAssertFalse(m.isFailure)
        XCTAssertNil(m.slotLine)
        XCTAssertEqual(HaltPanelModel.resumeKey(detail(nil)), "nextMajor")
    }

    func testUnknownKindsAndActionsDegrade() throws {
        let m = try XCTUnwrap(make(detail(halt("meteorStrike", actions: ["teleport", "retry"]))))
        XCTAssertEqual(m.buttons.map(\.action), [.retry])
        XCTAssertEqual(m.title, "Polish 5 failed", "the Mac's own words are shown for a kind the phone never heard of")
        XCTAssertEqual(try XCTUnwrap(make(detail(halt("x", actions: ["teleport"])))).buttons, [])
    }

    func testWhatAnOlderMacCannotDoIsNotOffered() throws {
        let all = ["retry", "retryOther", "toReview", "resume"]
        XCTAssertEqual(try XCTUnwrap(make(detail(halt(actions: all), retry: nil))).buttons.map(\.action), [.toReview, .resume])
        XCTAssertEqual(try XCTUnwrap(make(detail(halt(actions: all), editable: false))).buttons.map(\.action), [.retry, .toReview, .resume])
        XCTAssertEqual(try XCTUnwrap(make(detail(halt(actions: all), steer: nil))).buttons.map(\.action), [.retry], "the editor needs steer too")
    }

    func testInFlightAndLostConnectionDisableButtons() throws {
        let d = detail(halt(actions: ["retry", "toReview"]))
        let busy = try XCTUnwrap(make(d, inFlight: [.retry]))
        XCTAssertEqual(busy.buttons.map(\.title), ["Retrying…", "To review"])
        XCTAssertEqual(busy.buttons.map(\.enabled), [false, true])
        XCTAssertEqual(try XCTUnwrap(make(d, live: false)).buttons.map(\.enabled), [false, false])
    }

    func testOutputIsOfferedOnlyWhenTheMacSaysSoAndThereIsSome() throws {
        XCTAssertEqual(try XCTUnwrap(make(detail(halt(actions: ["showOutput"])))).output, "boom\nline2")
        XCTAssertNil(try XCTUnwrap(make(detail(halt(actions: ["retry"])))).output)
        XCTAssertNil(try XCTUnwrap(make(detail(halt(actions: ["showOutput"], output: "")))).output)
    }

    func testTheFailedSeatAndTheHaltedClock() throws {
        let m = try XCTUnwrap(make(detail(halt(actions: []))))
        XCTAssertEqual(m.slotLine, "Polisher · Gemini 3 Pro · high")
        let now = Date(timeIntervalSinceReferenceDate: 100 + 60), offset: TimeInterval = 12
        XCTAssertEqual(m.haltedFor(now: now, offset: offset, frozenAt: nil), "Halted for 1:12")
        XCTAssertEqual(m.haltedFor(now: now, offset: offset, frozenAt: Date(timeIntervalSinceReferenceDate: 100 + 10)), "Halted for 0:22")
        XCTAssertNil(try XCTUnwrap(make(detail(halt(actions: [], since: nil)))).haltedFor(now: now, offset: 0, frozenAt: nil))
    }

    func testRetrySendsIntakeRetryAndSettlesOnAck() {
        let c = RetryCommander()
        let id = UUID()
        let m = IntakeCommandModel(intake: id, commander: c)
        var acked = 0
        m.retry { acked += 1 }
        XCTAssertEqual(m.inFlight, [.retry])
        guard case .intakeRetry(let sent, _)? = c.commands.first else { return XCTFail("no intake.retry sent") }
        XCTAssertEqual(sent, id)
        m.retry { acked += 100 }
        XCTAssertEqual(c.commands.count, 1, "a second press while in flight is ignored")
        c.answer(.success(()))
        XCTAssertTrue(m.inFlight.isEmpty)
        XCTAssertEqual(acked, 1)
    }

    func testRetryRefusalShowsTheCommandCopy() {
        let c = RetryCommander()
        let m = IntakeCommandModel(intake: UUID(), commander: c)
        m.retry {}
        c.answer(.failure(.server(code: "not_allowed")))
        XCTAssertEqual(m.message, "That isn't possible right now.")
    }

    func testTheRowSaysWhyAFailedIntakeFailed() {
        let s = WireIntakeSummary(id: UUID(), title: "t", state: "failed", needsAttention: true, createdAt: Date(),
                                  haltKind: "intakeFailed", haltReason: "Harness error")
        XCTAssertEqual(IntakeRowStyle.fact(s, clock: nil), "Harness error")
    }
}
