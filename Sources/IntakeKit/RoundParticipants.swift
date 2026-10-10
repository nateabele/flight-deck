import Foundation

/// One agent the engine starts in a round: its raw role (`RoundExecutor.runName`'s role part),
/// its index among roles that repeat (drafters), and the slot the config seats it with — nil
/// when the config seats nobody there (a reviewer-less Sketch's refine), so a caller can still
/// list the seat rather than lose it.
public struct RoundParticipant: Equatable, Sendable {
    public var role: String
    public var index: Int?
    public var slot: Slot?

    public init(role: String, index: Int? = nil, slot: Slot?) {
        self.role = role
        self.index = index
        self.slot = slot
    }
}

/// Who runs a round, and which Refine rounds cross-check — the one derivation every reader of
/// "who runs round k" goes through: the planner's sequence (`TapePlanner`), the live card's
/// seat rows (`LiveSeats.expected`), the Rounds editor's timeline and the round chips in the
/// main view. Before it, the planner and the editor each spelled out first/last/every on their
/// own, and an editor that agrees with the runner only by coincidence is one edit from showing
/// a cross-check round the runner never runs.
public enum RoundParticipants {
    /// Whether Refine round `round` (1-based) of `total` cross-checks under `config`. "Last" is
    /// the last round as the stage stands now, so an extend moves it (coverage spec §3, §7).
    public static func crossChecks(round: Int, of total: Int, config: RoundConfig) -> Bool {
        guard config.crossChecks, let policy = config.crossCheck, round >= 1, round <= total else { return false }
        switch policy {
        case .off: return false
        case .firstAndLast: return round == 1 || round == total
        case .every: return true
        }
    }

    /// Every Refine round of `total` that cross-checks, in order.
    public static func crossCheckRounds(of total: Int, config: RoundConfig) -> [Int] {
        guard total > 0 else { return [] }
        return (1...total).filter { crossChecks(round: $0, of: total, config: config) }
    }

    /// The agents `round` starts, in the order `RoundExecutor` starts them. Synthesis lists the
    /// integrator because the engine runs it there (`RoundExecutor.synthesis` → `integrate`);
    /// fresh eyes and dedup run on the polisher, as polish does.
    public static func of(_ round: PlannedRound, config: RoundConfig) -> [RoundParticipant] {
        switch round.stage {
        case .draft:
            return config.drafters.enumerated().map { RoundParticipant(role: "drafter", index: $0.offset, slot: $0.element) }
        case .synthesis:
            return [RoundParticipant(role: "synthesizer", slot: config.synthesizer),
                    RoundParticipant(role: "integrator", slot: Slot(config.integrator))]
        case .refine:
            // The cross-reviewer sits between the two because that is the order the engine
            // starts them (`RoundExecutor.crossCheckRefine`), and the seat rows list in it.
            var out = [RoundParticipant(role: "reviewer", slot: config.reviewer)]
            if round.crossCheck { out.append(RoundParticipant(role: "crossReviewer", slot: config.crossReviewer)) }
            out.append(RoundParticipant(role: "integrator", slot: Slot(config.integrator)))
            return out
        case .encode:
            return [RoundParticipant(role: "encoder", slot: Slot(config.encoder))]
        case .polish, .freshEyes, .dedup:
            return [RoundParticipant(role: "polisher", slot: config.polisher.map { Slot($0) })]
        }
    }
}
