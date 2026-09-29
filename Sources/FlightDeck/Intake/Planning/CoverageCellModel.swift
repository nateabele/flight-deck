import Foundation
import IntakeKit

/// The LCD's COVERAGE cell (coverage spec §8): the band word over the cross-check it was read at,
/// and what its hover card says — the target, one row per reading, the notes and the action.
///
/// Every string here comes from the engine's `CoverageVerdict` — its state, readings, target and
/// suggested action — never re-derived, so the cell and the card can't disagree with the fold
/// or with each other. The first four fields are what `LCDModel` needs; the rest default so a
/// hand-made cell (a test or a render fixture) needs only those four.
struct CoverageCellModel: Equatable {
    /// "SATURATED", "FEW LEFT", "MANY LEFT", "NO OVERLAP", "STALLED", or "—" while there is no
    /// estimate (awaiting, same family, unmeasured).
    var word: String
    /// What a squeezed cell shows: "SAT", "FEW", "MANY", "NONE", "STALL", "—".
    var shortWord: String
    /// "cross-check R3", "cross-check pending", or "unmeasured".
    var caption: String
    /// Amber for STALLED and NO OVERLAP only — colour for exceptions only.
    var tone: LCDCell.Tone
    /// One line per reading, oldest first.
    var rows: [String] = []
    /// The integrator's declines and any doubt about how overlap was matched.
    var notes: [String] = []
    /// "Feature plan target: FEW LEFT or better · met at Refine 1"; nil for a preset with no target.
    var targetLine: String?
    /// The engine's `suggestedAction`; empty when it has nothing to suggest.
    var action: String = ""

    /// The action's first sentence, the part the card sets in bold.
    var actionHeadline: String? { ConvergenceCellModel.splitAction(action)?.headline }
    /// The rest of the action, if any.
    var actionDetail: String? { ConvergenceCellModel.splitAction(action)?.detail }
}

// In an extension, not the struct body: a custom init there would suppress the memberwise init
// the LCD tests and the render fixtures build hand-made cells with.
extension CoverageCellModel {
    /// Nil when the config doesn't cross-check and no reading exists: the cell is absent rather
    /// than a dash that could never change. A config switched off after a reading still shows it.
    /// `readings` are the card's rows, oldest first — the series the verdict was judged from;
    /// the verdict keeps only its latest, which is all the rows are without them.
    init?(verdict: CoverageVerdict, crossChecks: Bool, readings: [CoverageReading]? = nil) {
        guard crossChecks || verdict.latest != nil else { return nil }
        let latest = verdict.latest
        // A cross-reviewer that failed after the latest reading means the newest cross-check
        // measured nothing: the older round's band beside "unmeasured" would read as current.
        let failedSince = verdict.failedCrossCheckRound.map { $0 > (latest?.round ?? 0) } ?? false
        switch verdict.state {
        case .awaiting:
            (word, shortWord) = ("—", "—")
        case .stalled:
            (word, shortWord) = failedSince ? ("—", "—") : ("STALLED", "STALL")
        case .reading(let band):
            (word, shortWord) = failedSince ? ("—", "—") : Self.words(band)
        }
        tone = word == "STALLED" || word == "NO OVERLAP" ? .amber : .normal
        if failedSince || latest?.band == .sameFamily || latest?.band == .unmeasured {
            caption = "unmeasured"
        } else if let latest {
            caption = "cross-check R\(latest.round)"
        } else {
            caption = "cross-check pending"
        }
        rows = (readings ?? latest.map { [$0] } ?? []).map(Self.row)
        notes = latest.map(Self.notes) ?? []
        targetLine = Self.targetLine(verdict)
        action = verdict.suggestedAction
    }

    /// The shaping screen's cell: the engine's verdict over `readings`, told the refine cycle's
    /// convergence (a converged cycle short of target is a stall), how many refine rounds the
    /// planner would still run (a saturated R1 suggests trimming them), and the newest refine
    /// round whose cross-reviewer failed — which only a checkpoint's slots record. One derivation
    /// for the detail view and the service's flap seed, so the seeded word is the shown word.
    init?(intake: Intake, tape: Tape, config: RoundConfig, readings: [CoverageReading], cycles: [ConvergenceCycle]) {
        let refines = tape.checkpoints.filter { $0.stage == .refine }
        let planned = config.reviewer == nil ? 0 : config.refinementCap + tape.extraRefinement
        let failed = refines.last { cp in cp.record.slots.contains { $0.role == "crossReviewer" && $0.status == .failed } }?.round
        let verdict = CoverageSeries.verdict(readings: readings, preset: intake.chosenPreset ?? .featurePlan,
                                             convergence: cycles.last { $0.stage == .refine }?.verdict,
                                             refineRoundsRemaining: max(0, planned - refines.count),
                                             failedCrossCheckRound: failed)
        self.init(verdict: verdict, crossChecks: config.crossChecks, readings: readings)
    }

    private static func words(_ band: CoverageBand) -> (String, String) {
        switch band {
        case .saturated: ("SATURATED", "SAT")
        case .fewLeft: ("FEW LEFT", "FEW")
        case .manyLeft: ("MANY LEFT", "MANY")
        case .noOverlap: ("NO OVERLAP", "NONE")
        case .sameFamily, .unmeasured: ("—", "—")
        }
    }

    /// "Refine 1 · Codex 20 · Claude 18 · both 15 · ≈ 1 unfound (estimate)". A same-family
    /// reading has no estimate and drops that clause. An unmeasured one (no per-change verdicts,
    /// an older round) has no counts at all: its zeros are "not known", never "found nothing".
    private static func row(_ r: CoverageReading) -> String {
        if r.band == .unmeasured { return "Refine \(r.round) · unmeasured (no per-change verdicts)" }
        var parts = ["Refine \(r.round)", "\(r.familyA.displayName) \(r.n1)", "\(r.familyB.displayName) \(r.n2)", "both \(r.both)"]
        if let unfound = r.unfound { parts.append("≈ \(unfound) unfound (estimate)") }
        if r.band == .sameFamily { parts.append("same family, not independent") }
        return parts.joined(separator: " · ")
    }

    private static func notes(_ r: CoverageReading) -> [String] {
        var out: [String] = []
        if r.rejectedA + r.rejectedB > 0 {
            out.append("Integrator declined: \(r.familyA.displayName) \(r.rejectedA) · \(r.familyB.displayName) \(r.rejectedB)")
        }
        if r.correlated {
            out.append("\(r.familyA.displayName) and \(r.familyB.displayName) overlap on nearly every issue; the estimate may be low")
        }
        if r.matcher == .textSimilarity { out.append("Matched by text similarity: the integrator gave no groups") }
        if r.matchersDisagree, let text = r.textSimilarityBoth {
            out.append("Text matching finds \(text) in common; the integrator found \(r.both)")
        }
        return out
    }

    /// The target clause is left off while nothing can be judged against it (no reading yet, or
    /// one that can't speak to coverage): "not met" there would read as a measured shortfall.
    private static func targetLine(_ v: CoverageVerdict) -> String? {
        guard let label = v.target.label, let preset = preset(v.target) else { return nil }
        let head = "\(UIText.presetName(preset)) target: \(label)"
        switch v.targetMet {
        case true?: return "\(head) · met at Refine \(v.latest?.round ?? 0)"
        case false?: return "\(head) · not met"
        case nil: return head
        }
    }

    /// The preset a target belongs to, for its name. The verdict carries the target, not the
    /// preset; the two targets map back to exactly one preset each (`CoverageTarget.init`).
    private static func preset(_ target: CoverageTarget) -> Preset? {
        switch target {
        case .none: nil
        case .fewLeftOrBetter: .featurePlan
        case .saturatedIndependent: .fullPlan
        }
    }
}
