import XCTest
import IntakeKit
@testable import FlightDeck

/// The finished-rounds strip's pure parts: every card says the same things in the same places,
/// whatever kind of round it is; the detail panel's open card, caret and height.
final class FinishedRoundsModelTests: XCTestCase {
    private let codex = ModelChoice(harness: .codex, model: "gpt-6-sol", effort: "high")
    private let claude = ModelChoice(harness: .claude, model: "opus", effort: "high")
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    private func slot(_ role: String, _ status: SlotStatus) -> SlotOutcome {
        SlotOutcome(role: role, used: codex, requested: status == .substituted ? claude : codex, status: status)
    }

    /// One of every stage the strip can hold. The draft has no `startedAt` and nothing before it,
    /// so its duration is unknown; encode recorded no change count.
    private func everyKind() throws -> [RoundCard] {
        var intake = Intake(projectPath: "/tmp/project", intent: "per-project font size")
        intake.state = .shaping
        intake.roundConfig = try XCTUnwrap(PresetExpansion.config(for: .featurePlan, available: .defaults))
        let at = { (s: TimeInterval) in self.t0.addingTimeInterval(s) }
        let tape = Tape(checkpoints: [
            Checkpoint(id: 1, stage: .draft, round: 0, major: true, createdAt: at(600),
                       record: RoundRecord(slots: [slot("drafter", .ok), slot("drafter", .ok), slot("drafter", .ok)])),
            Checkpoint(id: 2, parent: 1, stage: .synthesis, round: 0, major: true, createdAt: at(1000),
                       record: RoundRecord(slots: [slot("synthesizer", .ok), slot("integrator", .substituted)],
                                           changeCount: 14, linesAdded: 42, linesRemoved: 17),
                       startedAt: at(620)),
            Checkpoint(id: 3, parent: 2, stage: .refine, round: 1, major: false, createdAt: at(1300),
                       record: RoundRecord(slots: [slot("reviewer", .failed), slot("integrator", .substituted)],
                                           changeCount: 1, linesAdded: 3, linesRemoved: 0,
                                           sectionsChanged: ["## Scope", "### Rollout plan"],
                                           tally: VerdictTally(agree: 11, somewhat: 2, disagree: 1),
                                           annotations: [PlanNote(note: "Keep the dispatcher override")],
                                           note: "Tightened the rollout."),
                       startedAt: at(1010)),
            Checkpoint(id: 4, parent: 3, stage: .encode, round: 0, major: true, createdAt: at(1400),
                       record: RoundRecord(slots: [slot("encoder", .ok)]), startedAt: at(1310)),
            Checkpoint(id: 5, parent: 4, stage: .polish, round: 1, major: false, createdAt: at(5000),
                       record: RoundRecord(changeCount: 6, linesAdded: 8, linesRemoved: 9), startedAt: at(1410)),
        ], status: .paused)
        return ShapingModel(intake: intake, tape: tape).roundCards
    }

    // MARK: - Card faces

    /// The request: every card the same fields in the same places. A field a round has no value
    /// for says "—" rather than vanishing, so the rows line up across the strip.
    func testEveryKindOfRoundFillsEveryField() throws {
        let faces = try everyKind().map(FinishedRoundsModel.face)
        XCTAssertEqual(faces.map(\.stage), ["DRAFT", "SYNTH", "REFINE", "ENCODE", "POLISH"])
        XCTAssertEqual(faces.map(\.name), ["Draft", "Synthesis", "Refine 1", "Encode", "Polish 1"])
        XCTAssertEqual(faces.map(\.duration), ["—", "6:20", "4:50", "1:30", "59:50"],
                       "the first round has neither its own start nor a previous landing")
        XCTAssertEqual(faces.map(\.work), ["3 drafts", "14 changes", "1 change", "—", "6 changes"])
        XCTAssertEqual(faces.map(\.lines), ["—", "+42/−17", "+3/−0", "+0/−0", "+8/−9"],
                       "a draft is written from nothing, so it has no lines")
        XCTAssertEqual(faces.map(\.verdicts), ["—", "—", "11 · 2 · 1", "—", "—"])
        for face in faces {
            for field in [face.stage, face.name, face.duration, face.work, face.lines, face.verdicts, face.outcomeText] {
                XCTAssertFalse(field.isEmpty, "\(face.name): every field is drawn, a missing one as —")
            }
        }
    }

    /// One glyph per card, the worst seat's: a card's glyph row used to be one glyph per seat,
    /// so a draft's three and an encode's one made cards different widths of the same thing.
    func testOutcomeIsTheWorstSeat() throws {
        let faces = try everyKind().map(FinishedRoundsModel.face)
        XCTAssertEqual(faces.map(\.outcome), [.ran, .fellBack, .failed, .ran, .unknown])
        XCTAssertEqual(faces.map(\.outcomeText), ["3 agents ran as asked", "1 of 2 agents fell back",
                                                  "1 of 2 agents failed", "1 agent ran as asked", "—"])
    }

    /// The card's short forms are shorthand; hover and VoiceOver get the whole thing.
    func testHelpAndAccessibilitySayTheFullValues() throws {
        let refine = FinishedRoundsModel.face(try everyKind()[2])
        XCTAssertEqual(refine.accessibilityLabel,
                       "Refine 1, 4:50, 1 change, +3/−0, agreed 11 · somewhat 2 · declined 1, 1 of 2 agents failed")
        XCTAssertEqual(refine.help, "Refine 1 · 4:50 · 1 change · +3/−0 · agreed 11 · somewhat 2 · declined 1 · 1 of 2 agents failed")
        let draft = FinishedRoundsModel.face(try everyKind()[0])
        XCTAssertEqual(draft.accessibilityLabel, "Draft, duration unknown, 3 drafts, no verdicts, 3 agents ran as asked",
                       "VoiceOver never reads a dash")
    }

    // MARK: - Detail

    /// The panel's facts are the same four for every round, in the same order.
    func testDetailFactsAreTheSameForEveryRound() throws {
        let details = try everyKind().map(FinishedRoundsModel.detail)
        for detail in details {
            XCTAssertEqual(detail.facts.map(\.label), ["Duration", "Changes", "Lines", "Verdicts"])
        }
        let refine = details[2]
        XCTAssertEqual(refine.title, "Refine 1")
        XCTAssertEqual(refine.facts.map(\.value), ["4:50", "1 change", "+3/−0", "agreed 11 · somewhat 2 · declined 1"])
        XCTAssertEqual(refine.note, "Tightened the rollout.")
        XCTAssertEqual(refine.sections, ["Scope", "Rollout plan"], "every section, not the card's first three")
        XCTAssertEqual(refine.notesApplied, ["Keep the dispatcher override"])
        XCTAssertEqual(refine.seats.map(\.label), ["reviewer", "integrator"])
        XCTAssertEqual(refine.seats.map(\.model), ["codex gpt-6-sol", "codex gpt-6-sol"])
        XCTAssertEqual(details[0].facts.map(\.value), ["—", "3 drafts", "—", "—"])
    }

    // MARK: - Open card

    func testClickingTheOpenCardClosesAndAnotherSwitches() {
        XCTAssertEqual(FinishedRoundsModel.toggled(open: nil, card: 3), 3)
        XCTAssertEqual(FinishedRoundsModel.toggled(open: 3, card: 3), nil)
        XCTAssertEqual(FinishedRoundsModel.toggled(open: 3, card: 5), 5, "another card switches in place")
    }

    /// ←/→ walk the strip while the panel is open, stopping at its ends; closed, they do nothing.
    func testArrowKeysStepTheOpenCard() {
        let ids = [1, 2, 4, 7]
        XCTAssertEqual(FinishedRoundsModel.step(open: 2, by: 1, in: ids), 4)
        XCTAssertEqual(FinishedRoundsModel.step(open: 2, by: -1, in: ids), 1)
        XCTAssertEqual(FinishedRoundsModel.step(open: 7, by: 1, in: ids), 7)
        XCTAssertEqual(FinishedRoundsModel.step(open: 1, by: -1, in: ids), 1)
        XCTAssertNil(FinishedRoundsModel.step(open: nil, by: 1, in: ids))
    }

    /// A rewind or trim can take the open round off the tape; the panel closes rather than
    /// describing a round that is gone.
    func testAnOpenCardThatLeftTheTapeCloses() {
        XCTAssertEqual(FinishedRoundsModel.resolve(open: 4, in: [1, 2, 4]), 4)
        XCTAssertNil(FinishedRoundsModel.resolve(open: 5, in: [1, 2, 4]))
        XCTAssertNil(FinishedRoundsModel.resolve(open: nil, in: [1, 2, 4]))
    }

    // MARK: - Caret and height

    /// The caret points at the card's centre, kept clear of the panel's rounded corners — a card
    /// scrolled half out of the strip pins it to the edge that way rather than off the panel.
    func testCaretFollowsTheCardAndStaysOnThePanel() {
        XCTAssertEqual(FinishedRoundsModel.caretX(cardMidX: 300, width: 800, margin: 20), 300)
        XCTAssertEqual(FinishedRoundsModel.caretX(cardMidX: -40, width: 800, margin: 20), 20)
        XCTAssertEqual(FinishedRoundsModel.caretX(cardMidX: 900, width: 800, margin: 20), 780)
        XCTAssertEqual(FinishedRoundsModel.caretX(cardMidX: nil, width: 800, margin: 20), 400,
                       "before the card has been measured")
    }

    func testPanelIsItsContentsHeightUpToTheCap() {
        XCTAssertEqual(FinishedRoundsModel.panelHeight(content: 140, cap: 360), 140)
        XCTAssertEqual(FinishedRoundsModel.panelHeight(content: 900, cap: 360), 360)
        XCTAssertEqual(FinishedRoundsModel.panelHeight(content: -3, cap: 360), 0)
        XCTAssertFalse(FinishedRoundsModel.scrolls(content: 360, cap: 360))
        XCTAssertTrue(FinishedRoundsModel.scrolls(content: 361, cap: 360))
    }
}
