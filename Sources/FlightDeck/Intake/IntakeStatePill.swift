import IntakeKit
import SwiftUI

/// The state pill drawn beside an intake in the list row and again in the detail header.
///
/// Mirrors `SessionStatusIcon`'s colour language rather than inventing a new one: orange
/// means "needs your attention" (the same meaning `.waiting` carries there), the accent
/// colour means the agent is actively working, green means shipped, and everything else is
/// a resting or terminal state that should not pull the eye.
struct IntakeStatePill: View {
    let intake: Intake
    /// The intake's tape while `.shaping` (`IntakeService.tapes`), so the pill can say where
    /// the rounds are rather than just "Shaping".
    var tape: Tape? = nil

    var body: some View {
        Text(Self.label(for: intake, tape: tape))
            .font(.caption.weight(.medium))
            .foregroundStyle(Self.tint(for: intake.state))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Self.tint(for: intake.state).opacity(0.15), in: Capsule())
            .accessibilityIdentifier("intake-state-pill")
    }

    /// Pure so every case can be pinned by `IntakeStatePillTests`. Takes the whole `Intake`
    /// rather than just `IntakeState` (the brief's original signature) because `released`
    /// needs the step count off `Intake.release`, which `IntakeState` alone cannot carry.
    /// Steps, not beads: `appliedSteps` counts every recheck and edge too, so a one-bead
    /// release read "released · 5 beads".
    static func label(for intake: Intake, tape: Tape? = nil) -> String {
        switch intake.state {
        case .triaging: return "triaging"
        case .needsAnswers: return "needs answers"
        case .awaitingChoice: return "choose fidelity"
        case .shaping: return tape.map(ShapingModel.pillLabel(for:)) ?? "Shaping"
        case .parked: return "parked"
        case .review: return "review"
        case .releasing: return "releasing"
        case .released:
            let n = intake.release?.appliedSteps ?? 0
            return "released · \(n) step\(n == 1 ? "" : "s")"
        case .partiallyReleased: return "partial"
        case .failed: return "failed"
        case .interrupted: return "interrupted"
        case .discarded: return "discarded"
        }
    }

    /// The state as the detail header's eyebrow names it ("INTAKE · SHAPING", spec §3): the
    /// stage in a word or two. The pill's `label` says where inside the stage things are; the
    /// header has the live card for that, so it names the stage only.
    static func stateName(_ state: IntakeState) -> String {
        switch state {
        case .triaging: "Triaging"
        case .needsAnswers: "Needs answers"
        case .awaitingChoice: "Choose fidelity"
        case .shaping: "Shaping"
        case .parked: "Parked"
        case .review: "Review"
        case .releasing: "Releasing"
        case .released: "Released"
        case .partiallyReleased: "Partially released"
        case .failed: "Failed"
        case .interrupted: "Interrupted"
        case .discarded: "Discarded"
        }
    }

    static func tint(for state: IntakeState) -> Color {
        switch state {
        case .needsAnswers, .awaitingChoice, .review, .partiallyReleased, .failed, .interrupted:
            return .orange
        case .triaging, .releasing, .shaping:
            return .accentColor
        case .released:
            return .green
        case .parked, .discarded:
            return .secondary
        }
    }
}
