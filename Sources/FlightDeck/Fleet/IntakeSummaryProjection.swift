import FleetKit
import Foundation
import IntakeKit

/// Intakes → the phone's coarse list rows (spec §6.1). Pure: no I/O, no clock of its own.
enum IntakeSummaryProjection {
    /// Released intakes stay on the phone's list this long (the maintainer, 2026-09-29), then leave it.
    static let releasedRetention: TimeInterval = 3 * 24 * 3600

    static func isListed(_ i: Intake, now: Date) -> Bool {
        switch i.state {
        case .discarded: return false
        case .released:
            guard let at = i.release?.releasedAt else { return true }
            return now.timeIntervalSince(at) <= releasedRetention
        default: return true
        }
    }

    static func summary(_ i: Intake, tape: Tape?, seats: SeatFiles?, needsAttention: Bool) -> WireIntakeSummary {
        var s = WireIntakeSummary(
            id: i.id, title: IntakeTitle(intent: i.intent).lead, state: i.state.rawValue,
            needsAttention: needsAttention, preset: (i.chosenPreset ?? i.recommended)?.rawValue,
            createdAt: i.createdAt)
        switch i.state {
        case .triaging:
            s.now = "Triage"
        case .needsAnswers:
            s.now = "Clarify \(i.exchanges.count)"
            s.questionCount = i.exchanges.last?.questions.count
        case .awaitingChoice, .parked:
            s.now = "Ready"
        case .review, .releasing:
            s.now = "Review"
        case .released, .partiallyReleased:
            s.now = "Review"
            s.releasedTaskCount = i.release?.idMap.count
        case .shaping, .failed, .interrupted, .discarded:
            break
        }
        if let tape, i.state == .shaping || i.state == .failed || i.state == .interrupted {
            s.runStatus = tape.status.rawValue
            if let round = tape.roundInProgress {
                s.now = BoardModel.name(stage: round.stage, round: round.round)
            } else if let head = tape.head {
                s.now = BoardModel.name(stage: head.stage, round: head.round)
            }
            switch tape.status {
            case .running: s.clockSince = tape.roundStartedAt ?? tape.head?.createdAt
            case .failed: s.clockSince = tape.failedAt
            case .idle, .paused, .stopped: s.clockSince = tape.head?.createdAt
            case .reachedReview: s.clockSince = nil
            }
            if tape.status == .running, let round = tape.roundInProgress, let seats {
                // `.distantPast`: the row's done/failed glyph does not depend on the clock, and
                // using it keeps this function free of `now`.
                let rows = LiveSeats.rows(round: round, config: i.roundConfig, seats: seats, now: .distantPast)
                s.agentsTotal = rows.count
                s.agentsDone = rows.filter { $0.model.glyph == .done || $0.model.glyph == .failed }.count
            }
        }
        return s
    }

    @MainActor
    static func summaries(for intakes: [Intake], service: IntakeService, now: Date) -> [WireIntakeSummary] {
        intakes.filter { isListed($0, now: now) }.map { i in
            summary(i, tape: service.tapes[i.id], seats: service.seats.files(i.id), needsAttention: service.needsAttention(i))
        }
    }

    /// One `projectIntakes` per project whose list differs, sorted by uuid string so a test can
    /// compare arrays. An absent key reads as nil, exactly as `FleetProjection` reads a missing
    /// cache entry — so no forced first event is needed for the mirror and the oracle to agree,
    /// and a startup refresh on a Mac with Flight Control off records nothing. A project present
    /// in `old` but gone from `new` emits nothing — `projectRemoved` already took it off the phone.
    static func changes(from old: [UUID: [WireIntakeSummary]?], to new: [UUID: [WireIntakeSummary]?]) -> [FleetEvent] {
        new.keys.sorted { $0.uuidString < $1.uuidString }.compactMap { id in
            let next = new[id] ?? nil
            return next == (old[id] ?? nil) ? nil : .projectIntakes(project: id, intakes: next)
        }
    }
}
