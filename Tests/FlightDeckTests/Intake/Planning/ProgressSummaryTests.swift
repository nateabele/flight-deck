import XCTest
import IntakeKit
@testable import FlightDeck

/// The header's one-line summary of finished phases (spec §3 item 1): what each phase took and
/// what it produced, from the tape's own timestamps and the plan text — never a guess.
final class ProgressSummaryTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    private func intake(_ state: IntakeState, exchanges: Int = 0) throws -> Intake {
        var intake = Intake(projectPath: "/tmp/project", intent: "per-project font size")
        intake.state = state
        intake.recommended = .fullPlan
        intake.roundConfig = try XCTUnwrap(PresetExpansion.config(for: .fullPlan, available: .defaults))
        intake.exchanges = (0..<exchanges).map { TriageExchange(questions: ["Q\($0)?"], answers: ["A\($0)"]) }
        return intake
    }

    /// Checkpoint `id` whose round ran from `start` to `end` seconds after `t0`.
    private func cp(_ id: Int, _ stage: Stage, _ round: Int = 0, from start: TimeInterval, to end: TimeInterval,
                    _ record: RoundRecord = RoundRecord()) -> Checkpoint {
        Checkpoint(id: id, parent: id > 1 ? id - 1 : nil, stage: stage, round: round, major: false,
                   createdAt: t0.addingTimeInterval(end), record: record, startedAt: t0.addingTimeInterval(start))
    }

    private func triage(seconds: TimeInterval, files: [String: Int]) -> SeatActivity {
        var a = SeatActivity(harness: .codex, startedAt: t0.addingTimeInterval(-1000))
        a.lastEventAt = a.startedAt.addingTimeInterval(seconds)
        a.footprint = files
        a.finished = true
        return a
    }

    private func flat(_ line: [(label: String, detail: String)]) -> [String] {
        line.map { "\($0.label)|\($0.detail)" }
    }

    func testSummaryAfterTriageOnly() throws {
        let line = ProgressSummary.line(intake: try intake(.awaitingChoice), tape: .empty,
                                        triage: triage(seconds: 220, files: ["Sources": 30, "docs": 11]))
        XCTAssertEqual(flat(line), ["Triage|3:40 · 41 files"])

        // Still triaging: nothing has finished yet, so there is nothing to summarise.
        XCTAssertEqual(flat(ProgressSummary.line(intake: try intake(.triaging), tape: .empty, triage: nil)), [])
        // Waiting on answers is mid-triage too.
        XCTAssertEqual(flat(ProgressSummary.line(intake: try intake(.needsAnswers, exchanges: 1), tape: .empty,
                                                 triage: nil)), [])
        // With clarifying rounds the only activity on hand is the LAST turn's — its clock and
        // footprint would under-report the whole of triage, so the rounds are what's said.
        let asked = ProgressSummary.line(intake: try intake(.awaitingChoice, exchanges: 2), tape: .empty,
                                         triage: triage(seconds: 40, files: ["Sources": 3]))
        XCTAssertEqual(flat(asked), ["Triage|2 rounds of questions"])
        // A relaunch forgets the activity: say it finished, and nothing invented.
        XCTAssertEqual(flat(ProgressSummary.line(intake: try intake(.awaitingChoice), tape: .empty, triage: nil)),
                       ["Triage|"])
    }

    func testSummaryAfterDraftAndSynthesis() throws {
        let tape = Tape(checkpoints: [cp(1, .draft, from: 0, to: 300), cp(2, .synthesis, from: 310, to: 592)])
        let plan = (1...412).map { "line \($0)" }.joined(separator: "\n") + "\n"
        let line = ProgressSummary.line(intake: try intake(.shaping), tape: tape,
                                        triage: triage(seconds: 220, files: ["Sources": 41])) { id, path in
            id == 2 && path == "plan.md" ? Data(plan.utf8) : nil
        }
        XCTAssertEqual(flat(line), ["Triage|3:40 · 41 files", "Draft & Synthesis|9:42 · 412 lines"],
                       "the 10 s the tape sat between rounds is not counted")

        // Draft alone (synthesis still running) is its own finished phase; the line count is
        // the lowest surviving draft's, the same plan the viewer shows for a draft checkpoint.
        let draftOnly = Tape(checkpoints: [cp(1, .draft, from: 0, to: 300)])
        let drafted = ProgressSummary.line(intake: try intake(.shaping), tape: draftOnly, triage: nil) { id, path in
            id == 1 && path == "drafts/0.md" ? Data("a\nb\nc".utf8) : nil
        }
        XCTAssertEqual(flat(drafted), ["Triage|", "Draft|5:00 · 3 lines"])

        // A tape from before round timestamps: no invented duration, the plan still counted.
        let old = Tape(checkpoints: [Checkpoint(id: 1, stage: .draft, round: 0, major: true, createdAt: t0)])
        XCTAssertEqual(flat(ProgressSummary.line(intake: try intake(.shaping), tape: old, triage: nil)),
                       ["Triage|", "Draft|"])
    }

    func testSummaryRefineCount() throws {
        let tape = Tape(checkpoints: [
            cp(1, .draft, from: 0, to: 300), cp(2, .synthesis, from: 300, to: 582),
            cp(3, .refine, 1, from: 600, to: 700), cp(4, .refine, 2, from: 700, to: 800),
            cp(5, .refine, 3, from: 800, to: 900),
        ])
        let line = ProgressSummary.line(intake: try intake(.shaping), tape: tape, triage: nil)
        XCTAssertEqual(flat(line), ["Triage|", "Draft & Synthesis|9:42", "Refine|×3"])
    }

    func testNoBeadWording() throws {
        let tape = Tape(checkpoints: [
            cp(1, .draft, from: 0, to: 300), cp(2, .synthesis, from: 300, to: 582),
            cp(3, .refine, 1, from: 600, to: 700),
            cp(4, .encode, from: 700, to: 800, RoundRecord(changeCount: 12)),
            cp(5, .polish, 1, from: 800, to: 900, RoundRecord(changeCount: 3)),
            cp(6, .polish, 2, from: 900, to: 950, RoundRecord(changeCount: 1)),
            cp(7, .freshEyes, from: 950, to: 990, RoundRecord(changeCount: 1)),
            cp(8, .dedup, from: 990, to: 999, RoundRecord(changeCount: 0)),
        ])
        let line = ProgressSummary.line(intake: try intake(.review), tape: tape, triage: nil)
        XCTAssertEqual(flat(line), [
            "Triage|", "Draft & Synthesis|9:42", "Refine|×1", "Encode|12 task changes", "Polish|×2",
            "Fresh eyes|1 change", "Dedup|0 changes",
        ])
        for text in line.flatMap({ [$0.label, $0.detail] }) {
            XCTAssertNil(text.range(of: "bead", options: .caseInsensitive), text)
        }
    }
}
