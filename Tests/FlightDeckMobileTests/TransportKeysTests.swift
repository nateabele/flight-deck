import FleetKit
import XCTest
@testable import FlightDeckMobile

final class TransportKeysTests: XCTestCase {
    static func detail(
        steer: Bool? = true, state: String = "shaping", halt: String? = nil,
        enabled: [String] = ["step", "nextMajor", "toReview", "pause", "stop", "extend", "trim"],
        defaultPlay: String = "nextMajor", extendStage: String? = "refine",
        trimStage: String? = "refine", cycleName: String? = "Refine", cyclePlanned: Int? = 5,
        controls: Bool = true
    ) -> WireIntakeDetail {
        WireIntakeDetail(
            etag: "e", project: UUID(),
            summary: WireIntakeSummary(id: UUID(), title: "T", state: state, needsAttention: false,
                                       runStatus: "running", createdAt: Date()),
            intent: "I",
            board: WireBoard(
                nowName: "Refine 2", nowChip: "ON COURSE", clockCaption: "IN THE AIR",
                stopsAt: "Encode", callingAt: "", defaultPlay: defaultPlay,
                controls: controls ? WireControls(
                    enabled: enabled, extendStage: extendStage, trimStage: trimStage,
                    cycleName: cycleName, cyclePlanned: cyclePlanned) : nil),
            halt: halt, servedAt: Date(), steer: steer)
    }

    private func key(_ id: String, _ keys: [TransportKey]) -> TransportKey { keys.first { $0.id == id }! }

    func testNoCommandIsSentWithoutSteer() {
        let d = Self.detail(steer: nil)
        XCTAssertEqual(TransportKeys.keys(detail: d, inFlight: []), [])
        XCTAssertNil(RoundsControlModel.make(detail: d, inFlight: []))
        XCTAssertFalse(NoteComposer.notesAllowed(detail: d))
    }

    func testNoKeysOutsideShapingOrWithoutControls() {
        XCTAssertEqual(TransportKeys.keys(detail: Self.detail(state: "planning"), inFlight: []), [])
        XCTAssertEqual(TransportKeys.keys(detail: Self.detail(controls: false), inFlight: []), [])
    }

    func testKeyOrderSymbolsAndCaptions() {
        let keys = TransportKeys.keys(detail: Self.detail(), inFlight: [])
        XCTAssertEqual(keys.map(\.id), ["pause", "step", "nextMajor", "toReview", "stop"])
        XCTAssertEqual(keys.map(\.symbol),
                       ["pause.fill", "forward.end.fill", "forward.end.alt.fill", "forward.fill", "stop.fill"])
        XCTAssertEqual(keys.map(\.caption), ["PAUSE", "STEP", "MAJOR", "REVIEW", "STOP"])
    }

    func testRunningEnablesOnlyPauseAndStop() {
        let keys = TransportKeys.keys(detail: Self.detail(enabled: ["pause", "stop"]), inFlight: [])
        XCTAssertEqual(keys.filter(\.enabled).map(\.id), ["pause", "stop"])
    }

    func testDefaultDotIsOnDefaultPlay() {
        let keys = TransportKeys.keys(detail: Self.detail(), inFlight: [])
        XCTAssertEqual(keys.filter(\.isDefault).map(\.id), ["nextMajor"])
    }

    func testPauseInFlightShowsPausing() {
        let keys = TransportKeys.keys(detail: Self.detail(), inFlight: [.tape("pause")])
        XCTAssertEqual(key("pause", keys).ack, "Pausing…")
        XCTAssertNil(key("stop", keys).ack)
        XCTAssertFalse(key("pause", keys).enabled)
    }

    func testHaltPausingShowsPausing() {
        let keys = TransportKeys.keys(detail: Self.detail(halt: "pausing"), inFlight: [])
        XCTAssertEqual(key("pause", keys).ack, "Pausing…")
    }

    /// The Mac already pausing (no press of ours in flight) is the same as ours: a second Pause
    /// would do nothing, so the key is off. Stop must stay live — stopping a run that is slow to
    /// pause is exactly what a person reaches for.
    func testHaltPausingAloneDisablesPauseButNotStop() {
        let keys = TransportKeys.keys(detail: Self.detail(halt: "pausing"), inFlight: [])
        XCTAssertFalse(key("pause", keys).enabled)
        XCTAssertTrue(key("stop", keys).enabled)
    }

    /// Only the play keys can become the default; a long press on Pause or Stop must not exist,
    /// or holding either for half a second swallows the press.
    func testOnlyPlayKeysCanBeTheDefault() {
        let keys = TransportKeys.keys(detail: Self.detail(), inFlight: [])
        XCTAssertEqual(keys.filter(\.canBeDefault).map(\.id), ["step", "nextMajor", "toReview"])
    }

    func testHaltStoppingDisablesEveryPlayKey() {
        let keys = TransportKeys.keys(detail: Self.detail(halt: "stopping"), inFlight: [])
        XCTAssertTrue(keys.allSatisfy { !$0.enabled })
        XCTAssertEqual(key("stop", keys).ack, "Stopping…")
    }

    func testStopInFlightDisablesEveryPlayKey() {
        let keys = TransportKeys.keys(detail: Self.detail(), inFlight: [.tape("stop")])
        XCTAssertTrue(keys.allSatisfy { !$0.enabled })
        XCTAssertEqual(key("stop", keys).ack, "Stopping…")
    }

    func testStopConfirmationText() {
        let c = TransportKeys.stopConfirmation(detail: Self.detail())
        XCTAssertEqual(c.title, "Stop the run?")
        XCTAssertEqual(c.message,
                       "Refine 2's work in progress is discarded. Landed rounds and your notes are kept.")
    }

    func testRoundsControl() throws {
        let r = try XCTUnwrap(RoundsControlModel.make(detail: Self.detail(), inFlight: []))
        XCTAssertEqual(r, RoundsControl(title: "Refine ×5", canTrim: true, canExtend: true, stage: "refine"))
        let busy = try XCTUnwrap(RoundsControlModel.make(detail: Self.detail(), inFlight: [.tape("trim")]))
        XCTAssertFalse(busy.canTrim)
        XCTAssertTrue(busy.canExtend)
        let off = try XCTUnwrap(RoundsControlModel.make(detail: Self.detail(enabled: ["extend"]), inFlight: []))
        XCTAssertFalse(off.canTrim)
        XCTAssertTrue(off.canExtend)
    }

    func testRoundsControlMixedStagesNeverOffersAMinusForAnotherStage() throws {
        let d = Self.detail(extendStage: "refine", trimStage: "polish")
        let r = try XCTUnwrap(RoundsControlModel.make(detail: d, inFlight: []))
        XCTAssertEqual(r.title, "Refine ×5")
        XCTAssertEqual(r.stage, "refine")
        XCTAssertTrue(r.canExtend)
        XCTAssertFalse(r.canTrim)
    }

    func testRoundsControlNilWithoutCycle() {
        XCTAssertNil(RoundsControlModel.make(detail: Self.detail(cycleName: nil), inFlight: []))
        XCTAssertNil(RoundsControlModel.make(detail: Self.detail(state: "planning"), inFlight: []))
    }
}
