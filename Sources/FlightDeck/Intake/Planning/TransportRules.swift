import Foundation
import IntakeKit

/// Which transport controls a tape allows right now, and which stage + and − act on — the ONE
/// rule the desktop's control bar, its Run menu, and the phone (via `WireControls`) all read, so
/// the phone can never offer a key the Mac would refuse. Moved out of `ShapingModel.enabled`
/// and `PlanningActions.shaping` unchanged.
struct TransportRules: Equatable {
    var enabled: Set<TransportButton>
    var extendStage: Stage?
    var trimStage: Stage?

    static func make(tape: Tape, config: RoundConfig?) -> TransportRules {
        var enabled: Set<TransportButton> = switch tape.status {
        case .running: [.pause, .stop, .annotate]
        case .paused, .idle, .stopped: [.step, .nextMajor, .toReview, .extend, .trim, .annotate]
        // ⏯ re-runs the round that failed; ⏭ is withheld because after a failure the human
        // should see one round succeed before committing to a whole stage again.
        case .failed: [.step, .toReview, .annotate]
        case .reachedReview: []
        }
        // Extend lengthens the current cycle — the stage the tape is in when that stage can still
        // grow, else the next one that can — and is withheld when nothing can (`TapePlanner` would
        // ignore it, so a lit + would be a silent no-op). Trim is its mirror.
        let current = tape.roundInProgress?.stage ?? tape.head?.stage
        let extendable = BoardModel.extendableStages(tape: tape, config: config)
        let trimmable = BoardModel.trimmableStages(tape: tape, config: config)
        let extendStage = extendable.first { $0 == current } ?? extendable.first
        let trimStage = trimmable.first { $0 == current } ?? trimmable.first
        if extendStage == nil { enabled.remove(.extend) }
        if trimStage == nil { enabled.remove(.trim) }
        return TransportRules(enabled: enabled, extendStage: extendStage, trimStage: trimStage)
    }
}
