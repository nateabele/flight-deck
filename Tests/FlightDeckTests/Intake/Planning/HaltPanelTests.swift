import XCTest
import IntakeKit
@testable import FlightDeck

/// The halt panel's glue: where "Retry with another model" moves the failed seat, and the
/// panel drawn for a real failure (a render, when `FD_PLANNING_RENDER_DIR` is set).
@MainActor
final class HaltPanelTests: XCTestCase {
    private let config = PresetExpansion.config(for: .fullPlan, available: .defaults)!
    private let failedAt = Date(timeIntervalSince1970: 1_800_000_000)

    private func slot(_ role: String, index: Int?) -> HaltStatus.Slot {
        HaltStatus.Slot(role: role, ran: "", harness: nil, model: nil, stage: nil, slotIndex: index)
    }

    private var other: ModelChoice { ModelChoice(agent: .codex, model: "other-model", effort: "high") }

    func testAppliedChoiceLandsOnTheFailedSeatsOnly() throws {
        let edited = try XCTUnwrap(HaltReseat.applying(other, to: slot("encoder", index: 0), in: config))
        XCTAssertEqual(edited.encoder, other)
        XCTAssertEqual(edited.integrator, config.integrator)
        XCTAssertEqual(edited.drafters, config.drafters)
    }

    func testADrafterIsAddressedByItsIndex() throws {
        let edited = try XCTUnwrap(HaltReseat.applying(other, to: slot("drafter", index: 1), in: config))
        XCTAssertEqual(edited.drafters[1].choice, other)
        XCTAssertEqual(edited.drafters[0], config.drafters[0])
    }

    func testARotatingRolesIndexWrapsOverItsEntries() throws {
        let count = config.polisherRotation.count
        let edited = try XCTUnwrap(HaltReseat.applying(other, to: slot("polisher", index: 4 % count), in: config))
        XCTAssertEqual(edited.polisherRotation[4 % count], other)
    }

    func testAnUnseatedOrUnknownRoleChangesNothing() {
        XCTAssertNil(HaltReseat.applying(other, to: slot("nobody", index: 0), in: config))
        XCTAssertNil(HaltReseat.applying(other, to: slot("drafter", index: 99), in: config))
    }

    func testOptionsLeaveOutTheSeatsOwnModelAndListItsAgentFirst() throws {
        let available = AvailableModels.defaults
        let current = try XCTUnwrap(RoundConfigEditor.choice(for: .encoder, in: config))
        let groups = HaltReseat.options(for: slot("encoder", index: 0), config: config, available: available)
        // The seat's own agent leads when it has another model to offer (the defaults may list one only).
        if let own = groups.firstIndex(where: { $0.agent == current.agent }) { XCTAssertEqual(own, 0) }
        XCTAssertFalse(groups.isEmpty)
        for group in groups {
            XCTAssertFalse(group.choices.contains { $0.agent == current.agent && $0.model == current.model })
            XCTAssertTrue(group.choices.allSatisfy { $0.agent == group.agent })
        }
        for choice in groups.first { $0.agent == current.agent }?.choices ?? [] { XCTAssertEqual(choice.effort, current.effort) }
    }

    func testKindsReadRedForFailuresAndAmberForTheRest() {
        XCTAssertTrue(HaltStatus.Kind.roundFailed.isFailure)
        XCTAssertTrue(HaltStatus.Kind.interrupted.isFailure)
        XCTAssertFalse(HaltStatus.Kind.paused.isFailure)
        XCTAssertFalse(HaltStatus.Kind.rateLimited.isFailure)
    }

    func testSlotTextFallsBackToIdsWhenNoDisplayNameWasGiven() {
        XCTAssertEqual(HaltPanel.slotText(HaltStatus.Slot(role: "polisher", ran: "Gemini 3 · high", harness: nil, model: nil, stage: nil, slotIndex: 0)),
                       "polisher · Gemini 3 · high")
        XCTAssertEqual(HaltPanel.slotText(HaltStatus.Slot(role: "polisher", ran: "", harness: "agy", model: "m", stage: nil, slotIndex: 0)),
                       "polisher · agy · m")
        XCTAssertEqual(HaltPanel.slotText(slot("encoder", index: nil)), "encoder")
    }

    func testRenderHaltPanel() throws {
        guard let dir = ProcessInfo.processInfo.environment["FD_PLANNING_RENDER_DIR"] else {
            throw XCTSkip("set FD_PLANNING_RENDER_DIR to render the halt panel PNGs")
        }
        let out = URL(fileURLWithPath: dir)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let halts: [(String, HaltStatus)] = [
            ("failed", HaltStatus(
                kind: .roundFailed, title: "Polish 5 failed",
                reason: "Agent error: error: There was a network issue connecting to the server, please try again.",
                whatToDo: "Retry, or change this slot.", since: Date().addingTimeInterval(-754),
                slot: HaltStatus.Slot(role: "polisher", ran: "Gemini 3 Pro · high", harness: "agy", model: "gemini", stage: .polish, slotIndex: 4),
                output: "AGY_ERROR: dial tcp: lookup daily-cloudcode-pa.googleapis.com: no such host\nretryable: true",
                actions: [.retry, .retryOther, .toReview, .showOutput])),
            ("paused", HaltStatus(
                kind: .paused, title: "Paused after Refine 2", reason: "Planning is paused.", whatToDo: nil,
                since: Date().addingTimeInterval(-95), slot: nil, output: nil, actions: [.resume, .toReview])),
        ]
        for (name, halt) in halts {
            for (appearance, look) in [(NSAppearance.Name.darkAqua, "dark"), (.aqua, "light")] {
                let view = HaltPanel(status: halt, reseat: [], outputOpen: true, perform: { _ in }).padding(16)
                try PlanningRender.write(view, size: NSSize(width: 640, height: 330),
                                         to: out.appendingPathComponent("halt-panel-\(name)-\(look).png"), appearance: appearance)
            }
        }
    }
}
