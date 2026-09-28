import Foundation
import IntakeKit
@testable import FlightDeck

/// The fieldOS plan-churn fixture behind every convergence render: a scenario names how many
/// lines each round rewrites per section and the reviewer agreement, and `plan(_:after:)` folds
/// that into a real `plan.md` whose round-to-round diffs are what the engine's convergence fold
/// actually reads. Shared by `ConvergenceRenderTests` (the heatmap card, collapsed/expanded) and
/// `PlanningRenderTests` (the same three states at both control-bar widths) so both draw from one
/// fixture instead of two copies drifting apart.
struct ConvergenceScenario {
    let name: String
    let counts: [Int]
    let agree: [Double]
    let touched: [[Int]]
    var models: [Int: ModelChoice] = [:]
    var extra = 0
    var proposals: [Int: [ProposedChange]] = [:]
}

enum ConvergenceFixture {
    static let sections: [(title: String, lines: [String])] = [
        ("1. Overview", ["fieldOS schedules field-service work for mid-size HVAC and electrical contractors.",
                         "A dispatcher assigns jobs on a live board.", "Technicians check in from the site on their phones.",
                         "Customers are told when a technician is on the way.", "The first release covers one region."]),
        ("2. Technicians", ["Each technician has skills, a home depot and working hours.",
                            "Skills are tagged by trade and certification level.", "Working hours are set per weekday.",
                            "A technician may mark a day as unavailable.", "Travel starts from the home depot.",
                            "Overtime needs a dispatcher's approval.", "A technician carries at most one van.",
                            "Vans have a stock list the job may need.", "Certifications expire and must be renewed.",
                            "Expired certifications hide the matching skill.", "Technicians see only their own jobs.",
                            "A lead technician can see the whole crew."]),
        ("3. Jobs", ["A job has a site, a window, required skills and an estimate.", "Windows are two hours long.",
                     "Estimates come from the job type.", "A job moves through new, assigned, enRoute, onSite and done.",
                     "A cancelled job keeps its history.", "Repeat visits link to the original job.",
                     "Photos attach to the job, not the technician.", "Parts used are recorded at close.",
                     "A job may need two technicians.", "Emergency jobs jump the queue.",
                     "Jobs outside the region are refused.", "Every change is logged with who made it.",
                     "A job's site can have access notes.", "Customers may reschedule once without a fee."]),
        ("4. Dispatch rules", ["A job is offered to the best-scoring available technician.",
                               "Skill match is a soft constraint: a dispatcher may override it with a reason.",
                               "Availability and the travel buffer are hard constraints.",
                               "Score = skill fit × 0.5 + proximity × 0.3 + load balance × 0.2.",
                               "A job with no candidate stays Unassigned until a dispatcher assigns it.",
                               "Auto-assignment is out of scope for v1.", "Max 6 jobs per technician per day.",
                               "The travel buffer is 20 minutes between jobs.", "Emergency jobs may break the daily cap.",
                               "A dispatcher can pin a job to a technician.", "Pinned jobs are never re-offered.",
                               "Declined offers go to the next-best technician."]),
        ("5. Mobile check-in", ["Check-ins queue in CheckInOutbox while offline.", "The outbox replays oldest-first on reconnect.",
                                "A check-in more than 200 m from the site asks for a reason.", "Check-out requires a signature.",
                                "Photos upload on Wi-Fi only by default.", "The app works for a full day offline.",
                                "A failed replay is shown to the technician.", "The dispatcher sees the last known position.",
                                "Location is sampled only during a job."]),
        ("6. Notifications", ["The customer gets an SMS when the technician is en route.", "The SMS carries a live ETA link.",
                              "A dispatcher is pushed when a job sits unassigned for 30 minutes.",
                              "Technicians get a push for a new job.", "Quiet hours hold non-urgent pushes."]),
        ("7. Testing", ["Dispatch scoring is a pure function with table tests.",
                        "Offline replay has a simulated-network suite.", "The board has one UI test per hard constraint.",
                        "Check-in distance rules are property-tested.", "Every notification has a template test."]),
    ]

    /// Round `r`'s wording for a line it rewrote.
    static let revisions = ["", " Confirmed with the dispatch leads.", " Tightened after review.",
                            " Reworded for the pilot.", " Revisited against the field data."]

    /// The plan after `round` rounds: each section's lines carry the wording of the last round
    /// that touched them.
    static func plan(_ scenario: ConvergenceScenario, after round: Int) -> String {
        var out = "# Field-service scheduling platform\n\n"
        for (s, section) in sections.enumerated() {
            var last = Array(repeating: 0, count: section.lines.count)
            var cursor = 0
            for r in 0..<round {
                for k in 0..<scenario.touched[s][r] { last[(cursor + k) % section.lines.count] = r + 1 }
                cursor += scenario.touched[s][r]
            }
            out += "## \(section.title)\n\n"
            for (i, line) in section.lines.enumerated() {
                out += "- " + line + (last[i] == 0 ? "" : revisions[last[i] % revisions.count].replacingOccurrences(of: ".", with: " (R\(last[i])).")) + "\n"
            }
            out += "\n"
        }
        return out
    }

    static func writeTape(_ scenario: ConvergenceScenario, for id: UUID, store: IntakeStore,
                          now: Date, codex: ModelChoice, claude: ModelChoice) throws {
        let tapes = TapeStore(intakeDirectory: store.directory(for: id))
        let slot = { (role: String, used: ModelChoice) in SlotOutcome(role: role, used: used, requested: used, status: .ok) }
        var tape = Tape()
        tape.extraRefinement = scenario.extra
        try tapes.saveTape(tape)
        let rounds = scenario.counts.count
        var t = now.addingTimeInterval(-Double(600 + rounds * 300))
        let draft = Data(plan(scenario, after: 0).utf8)
        try tapes.writeCheckpoint(
            Checkpoint(id: 1, stage: .draft, round: 0, major: true, createdAt: t,
                       record: RoundRecord(slots: [slot("drafter", codex), slot("drafter", claude)], linesAdded: 412),
                       startedAt: t.addingTimeInterval(-400)),
            files: ["drafts/0.md": draft], into: &tape)
        t += 180
        try tapes.writeCheckpoint(
            Checkpoint(id: 2, parent: 1, stage: .synthesis, round: 0, major: true, createdAt: t,
                       record: RoundRecord(slots: [slot("synthesizer", claude), slot("integrator", codex)], changeCount: 14,
                                           linesAdded: 30, linesRemoved: 12, tally: VerdictTally(agree: 11, somewhat: 2, disagree: 1)),
                       startedAt: t.addingTimeInterval(-180)),
            files: ["plan.md": draft], into: &tape)
        for r in 1...rounds {
            t += 290
            let agree = Int((scenario.agree[r - 1] * 100).rounded())
            let reviewer = scenario.models[r] ?? codex
            var files = ["plan.md": Data(plan(scenario, after: r).utf8)]
            if let proposals = scenario.proposals[r] {
                files["changes.json"] = try IntakeJSON.encoder.encode(proposals)
                files["verdicts.json"] = try IntakeJSON.encoder.encode([ChangeVerdict(index: 0, verdict: r == 3 ? .somewhat : .agree)])
            }
            let churn = scenario.touched.map { $0[r - 1] }.reduce(0, +)
            try tapes.writeCheckpoint(
                Checkpoint(id: 2 + r, parent: 1 + r, stage: .refine, round: r, major: r == rounds, createdAt: t,
                           record: RoundRecord(slots: [slot("reviewer", reviewer), slot("integrator", codex)],
                                               changeCount: scenario.counts[r - 1], linesAdded: churn, linesRemoved: churn,
                                               tally: VerdictTally(agree: agree, somewhat: 0, disagree: 100 - agree)),
                           startedAt: t.addingTimeInterval(-280)),
                files: files, into: &tape)
        }
        tape.status = .paused
        try tapes.saveTape(tape)
    }

    /// The three named scenarios `ConvergenceRenderTests`/`PlanningRenderTests` both render.
    static let hotSection = "4. Dispatch rules"
    static func standardScenarios(claude: ModelChoice) -> [ConvergenceScenario] {
        [
            ConvergenceScenario(name: "converging", counts: [41, 14, 5], agree: [0.70, 0.82, 0.90],
                                touched: [[4, 0, 0], [10, 3, 0], [6, 2, 0], [8, 4, 2], [6, 2, 1], [3, 0, 0], [4, 1, 1]]),
            ConvergenceScenario(name: "plateau", counts: [38, 14, 12, 13], agree: [0.72, 0.74, 0.73, 0.72],
                                touched: [[3, 0, 0, 0], [8, 2, 0, 0], [5, 3, 2, 1], [6, 4, 3, 2], [4, 3, 4, 2], [2, 1, 2, 2], [3, 1, 0, 1]],
                                models: [3: claude, 4: claude], extra: 1),
            ConvergenceScenario(name: "diverging", counts: [36, 15, 22, 29], agree: [0.76, 0.80, 0.57, 0.48],
                                touched: [[4, 0, 0, 0], [10, 3, 0, 0], [8, 6, 4, 3], [5, 3, 7, 11], [6, 3, 2, 1], [3, 1, 0, 0], [4, 2, 1, 1]],
                                extra: 1,
                                proposals: [
                                    1: [ProposedChange(section: hotSection, rationale: "Unassigned jobs need an owner",
                                                       edit: "A job with no candidate stays Unassigned for 24 hours, then goes to the nearest technician.")],
                                    2: [ProposedChange(section: hotSection, rationale: "Auto-assignment surprises dispatchers",
                                                       edit: "A job with no candidate stays Unassigned until a dispatcher assigns it.")],
                                    3: [ProposedChange(section: hotSection, rationale: "Dispatchers are a bottleneck",
                                                       edit: "A job with no candidate is auto-assigned after 4 hours to the least-loaded technician.")],
                                    4: [ProposedChange(section: hotSection, rationale: "Auto-assignment surprises dispatchers",
                                                       edit: "A job with no candidate stays Unassigned until a dispatcher assigns it.")],
                                ]),
        ]
    }
}
