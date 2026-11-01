import FleetKit
import Foundation
import IntakeKit

/// Why planning stopped and what the person can do about it — the ONE reading the desktop's halt
/// panel and the phone's (via `wire`) both draw, so they say the same words and never offer what
/// the Mac would refuse. Pure: the caller hands in the tape, the config and the failed seat's
/// output tail, so nothing here touches disk or the clock.
///
/// Actions come from `TransportRules` (the transport keys) and `IntakeService.retry`'s own
/// guard (an intake that failed or was interrupted), never a rule of their own.
struct HaltStatus: Equatable {
    enum Kind: String { case roundFailed, intakeFailed, interrupted, paused, stopped, rateLimited }
    enum Action: String, CaseIterable { case retry, retryOther, toReview, resume, showOutput }
    struct Slot: Equatable {
        var role: String
        var ran: String
        var harness: String?
        var model: String?
        var stage: Stage?
        var slotIndex: Int?
    }

    var kind: Kind
    var title: String
    var reason: String
    var whatToDo: String?
    var since: Date?
    var slot: Slot?
    var output: String?
    var actions: [Action]

    /// The most of a failed agent's output that travels: the end is kept, because that is where
    /// the harness says why it died.
    static let outputLimit = 4000

    /// nil when nothing is halted (running, reached review, released…).
    ///
    /// `failedRole` names the seat that failed (`failedSeat(round:config:seats:)`); without it the
    /// slot is only known for a round with one seat, since guessing between seats would send
    /// "Retry with another model" to the wrong one.
    static func make(
        intake: Intake, tape: Tape?, config: RoundConfig?, failedSeatOutput: String?,
        rateLimitedAt: Date?, available: AvailableModels, failedRole: String? = nil
    ) -> HaltStatus? {
        switch intake.state {
        case .failed, .interrupted:
            let failed = intake.state == .failed
            let output = tail(intake.rawFailureOutput)
            return HaltStatus(
                kind: failed ? .intakeFailed : .interrupted,
                title: failed ? "Planning failed" : "Planning was interrupted",
                reason: intake.failure ?? (failed ? "Planning failed." : "Planning was interrupted."),
                whatToDo: nil, since: nil, slot: nil, output: output,
                actions: [.retry] + (output == nil ? [] : [.showOutput]))
        case .shaping:
            guard let tape else { return nil }
            return shaping(tape: tape, config: config ?? intake.roundConfig, output: failedSeatOutput,
                           rateLimitedAt: rateLimitedAt, available: available, failedRole: failedRole)
        default:
            return nil
        }
    }

    private static func shaping(
        tape: Tape, config: RoundConfig?, output: String?, rateLimitedAt: Date?,
        available: AvailableModels, failedRole: String?
    ) -> HaltStatus? {
        let rules = TransportRules.make(tape: tape, config: config)
        let head = tape.head.map { BoardModel.name(stage: $0.stage, round: $0.round) }
        switch tape.status {
        case .failed:
            let round = config.flatMap { TapePlanner.upcoming(after: tape, config: $0).first }
            let diagnosis = tape.pauseDiagnosis
            let slot = round.flatMap { r in config.flatMap { Self.slot(of: r, config: $0, role: failedRole, available: available) } }
            let output = tail(output)
            // Retry is ⏯ on a failed tape, so it is offered exactly when the Mac would take ⏯.
            // Another model is the same retry after a Rounds-editor save, which the failed tape
            // allows once its runner is gone (`DetailLayout.roundsEditing`).
            let canRetry = rules.enabled.contains(.step)
            var actions: [Action] = []
            if canRetry { actions.append(.retry) }
            if canRetry, slot?.slotIndex != nil { actions.append(.retryOther) }
            if rules.enabled.contains(.toReview) { actions.append(.toReview) }
            if output != nil { actions.append(.showOutput) }
            return HaltStatus(
                kind: diagnosis?.category == .rateLimited ? .rateLimited : .roundFailed,
                title: (round.map { BoardModel.name(stage: $0.stage, round: $0.round) } ?? head ?? "Round") + " failed",
                reason: diagnosis.map { ShapingModel.categoryTitle($0.category) + ": " + $0.detail } ?? "Round failed",
                whatToDo: diagnosis?.action, since: tape.failedAt ?? tape.head?.createdAt,
                slot: slot, output: output, actions: actions)
        case .paused, .stopped:
            let stopped = tape.status == .stopped
            var actions: [Action] = []
            if rules.enabled.contains(.step) { actions.append(.resume) }
            if rules.enabled.contains(.toReview) { actions.append(.toReview) }
            return HaltStatus(
                kind: stopped ? .stopped : .paused,
                title: head.map { (stopped ? "Stopped after " : "Paused after ") + $0 } ?? (stopped ? "Stopped" : "Paused"),
                reason: stopped ? "You stopped planning." : "Planning is paused.",
                whatToDo: nil, since: tape.head?.createdAt, slot: nil, output: nil, actions: actions)
        case .running:
            guard let rateLimitedAt else { return nil }
            let name = tape.roundInProgress.map { BoardModel.name(stage: $0.stage, round: $0.round) }
            return HaltStatus(
                kind: .rateLimited, title: name.map { "\($0) is rate limited" } ?? "Rate limited",
                reason: "An agent hit its rate limit and is waiting.",
                whatToDo: nil, since: rateLimitedAt, slot: nil, output: nil, actions: [])
        case .idle, .reachedReview:
            return nil
        }
    }

    /// `text`'s end, or nil when there is nothing to show.
    private static func tail(_ text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        return IntakeDetailProjection.tail(text, limit: outputLimit)
    }

    /// The seat of `round` that failed, as the Rounds editor addresses it (`slotIndex`).
    private static func slot(of round: PlannedRound, config: RoundConfig, role: String?, available: AvailableModels) -> Slot? {
        let seats = RoundParticipants.of(round, config: config)
        guard let seat = seats.first(where: { $0.role == role }) ?? (seats.count == 1 ? seats.first : nil),
              let choice = seat.slot?.choice else { return nil }
        // A rotating role's turn wraps over its entries, as `RoundConfig` reads it.
        func turn(_ entries: Int) -> Int { entries > 0 ? round.rotation % entries : 0 }
        let index: Int? = switch seat.role {
        case "drafter": seat.index
        case "reviewer": turn(config.reviewerRotation.count)
        case "integrator": turn(config.integratorRotation.count)
        case "polisher": turn(config.polisherRotation.count)
        // The cross-check agent has no row of its own in the editor to address by index.
        case "crossReviewer": nil
        default: 0
        }
        let ran = ([available.modelLabel(agent: choice.agent, model: choice.model, account: choice.account)]
                   + (choice.effort.isEmpty ? [] : [choice.effort])).joined(separator: " · ")
        return Slot(role: seat.role, ran: ran, harness: choice.agent.rawValue, model: choice.model,
                    stage: round.stage, slotIndex: index)
    }

    /// The seat of `round` that failed — its role and the name of the run directory holding its
    /// output — read off the same rows the live card draws.
    static func failedSeat(round: PlannedRound, config: RoundConfig, seats: SeatFiles) -> (role: String, run: String)? {
        let rows = LiveSeats.rows(round: round, config: config, seats: seats, now: .distantPast)
        for seat in RoundParticipants.of(round, config: config) {
            let base = "\(round.stage.rawValue)-\(round.round)-" + seat.role + (seat.index.map { "-\($0)" } ?? "")
            if let row = rows.first(where: { $0.id == base }), row.model.glyph == .failed { return (seat.role, row.model.id) }
        }
        return nil
    }

    var wire: WireHalt {
        WireHalt(
            kind: kind.rawValue, title: title, reason: reason, whatToDo: whatToDo, since: since,
            slot: slot.map {
                WireHaltSlot(role: $0.role, ran: $0.ran, harness: $0.harness, model: $0.model,
                             stage: $0.stage?.rawValue, slotIndex: $0.slotIndex)
            },
            output: output, actions: actions.map(\.rawValue))
    }
}
