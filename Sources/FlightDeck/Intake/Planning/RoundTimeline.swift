import IntakeKit

/// One round of a tape, by the `(stage, round)` pair the planner, the checkpoints and
/// `roundInProgress` all identify rounds by — so a chip in the inspector and a card in the main
/// view name the same round without either holding a checkpoint id the other may not have yet.
struct RoundKey: Hashable {
    var stage: Stage
    var round: Int
}

/// What a round chip shows — the inspector's timeline and the main view's round cards and live
/// header all draw `RoundChip` from one of these, built by `RoundTimeline`, so the two sides
/// can't disagree about a round's name, agents, cross-check or progress.
struct RoundChipModel: Equatable, Identifiable {
    enum Progress: Equatable { case planned, done, live }

    var key: RoundKey
    /// The board's name, "Refine 2" (`BoardModel.name`).
    var name: String
    /// Who runs it: for a round that ran, who actually ran (a fallback's model); otherwise the
    /// config's agents for exactly this round (`RoundParticipants`).
    var agents: [RoundAgent]
    var crossCheck: Bool
    var progress: Progress
    /// The round's checkpoint, once it ran — what selecting the chip shows in the main view.
    var checkpointID: Int?

    var id: RoundKey { key }
    var section: RoundsSection { .of(key.stage) }

    /// "Refine 1, cross-check, done" — the chip reads as one element; the agents follow in the
    /// stack's own wording.
    var accessibilityLabel: String {
        var parts = [name]
        if crossCheck { parts.append("cross-check") }
        switch progress {
        case .planned: break
        case .done: parts.append("done")
        case .live: parts.append("running")
        }
        return parts.joined(separator: ", ")
    }

    var help: String {
        var lines = [name + (crossCheck ? " · cross-check: a second agent family reviews too" : "")]
        let agents = AgentStackModel.help(agents)
        if !agents.isEmpty { lines.append(agents) }
        return lines.joined(separator: "\n")
    }
}

/// The Rounds editor's timeline and the chips both sides of the planning view share — pure, so
/// `RoundTimelineTests` pins every stage/chip derivation, done/live mark and selection rule.
enum RoundTimeline {
    /// One row per stage in run order. `chips` may be empty (a refine cap of 0): the row still
    /// shows, because its pickers and cap live under it.
    struct Row: Equatable {
        var section: RoundsSection
        var chips: [RoundChipModel]
    }

    /// The inspector's selection: the stage whose pickers are revealed, and the chip picked in
    /// it, if any — clicking a stage's name selects the stage alone.
    struct Selection: Equatable {
        var section: RoundsSection
        var round: RoundKey?

        static func round(_ key: RoundKey) -> Selection { Selection(section: .of(key.stage), round: key) }
    }

    // MARK: - Chips

    /// The chip for a round that has not run, or is running: the config's agents for exactly
    /// this round (its cross-check included), from the one participants function the runner uses.
    static func chip(_ round: PlannedRound, config: RoundConfig?, progress: RoundChipModel.Progress = .planned) -> RoundChipModel {
        RoundChipModel(key: RoundKey(stage: round.stage, round: round.round),
                       name: BoardModel.name(stage: round.stage, round: round.round),
                       agents: config.map { AgentStackModel.planned(stage: round.stage, crossCheck: round.crossCheck, config: $0) } ?? [],
                       crossCheck: round.stage == .refine && round.crossCheck, progress: progress)
    }

    /// The chip for a round on the tape: who actually ran it, and whether a cross-check agent was
    /// among them. A record from before rounds kept their slots falls back to the config.
    static func chip(_ checkpoint: Checkpoint, config: RoundConfig?) -> RoundChipModel {
        let record = checkpoint.record
        let crossed = record.slots.contains { $0.role == "crossReviewer" }
        var chip = chip(PlannedRound(stage: checkpoint.stage, round: checkpoint.round, major: checkpoint.major, crossCheck: crossed),
                        config: config, progress: .done)
        if !record.slots.isEmpty { chip.agents = AgentStackModel.ran(record) }
        chip.checkpointID = checkpoint.id
        return chip
    }

    /// The round in flight — `roundInProgress`, or the start a play just asked for — as the live
    /// header draws it, carrying the cross-check it started with.
    static func live(tape: Tape, starting: PlannedRound?, config: RoundConfig?) -> RoundChipModel? {
        (tape.roundInProgress ?? starting).map { chip($0, config: config, progress: .live) }
    }

    // MARK: - Rows

    /// The editor's rows: every round the tape plans now (`TapePlanner.plannedRounds`, its
    /// extend/trim counters in), each marked done once its checkpoint is on the tape and live
    /// while it runs. A checkpoint the rebuilt sequence no longer plans (a config changed under
    /// the tape) still shows, done: it ran. With no tape (before shaping), every chip is planned.
    static func rows(config: RoundConfig, tape: Tape?, starting: PlannedRound? = nil) -> [Row] {
        let tape = tape ?? .empty
        var done: [RoundKey: RoundChipModel] = [:]
        // The newest checkpoint for a key speaks for it — a rewound round that ran again.
        for cp in tape.checkpoints { done[RoundKey(stage: cp.stage, round: cp.round)] = chip(cp, config: config) }
        let live = live(tape: tape, starting: starting, config: config)

        var chips: [RoundChipModel] = TapePlanner.plannedRounds(config: config, tape: tape).map { round in
            let key = RoundKey(stage: round.stage, round: round.round)
            if let ran = done.removeValue(forKey: key) { return ran }
            if let live, live.key == key { return live }
            return chip(round, config: config)
        }
        if let live, !chips.contains(where: { $0.key == live.key }) { chips.append(live) }
        chips += done.values
        chips.sort { (BoardModel.rank($0.key.stage), $0.key.round) < (BoardModel.rank($1.key.stage), $1.key.round) }

        return sections(config: config).map { section in
            Row(section: section, chips: chips.filter { $0.section == section })
        }
    }

    /// The stages the editor has a row for: those with a seat to pick. Synthesis needs a
    /// synthesizer and Polish a polisher (`TapePlanner.sequence` plans neither without one);
    /// Refine always shows, because the integrator — which every fidelity seats — is set there.
    static func sections(config: RoundConfig) -> [RoundsSection] {
        RoundsSection.allCases.filter { section in
            switch section {
            case .synthesis: config.synthesizer != nil
            case .polish: config.polisher != nil
            case .draft, .refine, .encode: true
            }
        }
    }

    /// Under a stage's pickers: what an edit there reaches. The model is role-based, so a
    /// change applies to every round of the stage, never to the one chip picked.
    static func caption(_ section: RoundsSection) -> String {
        switch section {
        case .refine, .polish: "Applies to every \(section.title) round"
        case .draft, .synthesis, .encode: "Applies to the \(section.title) round"
        }
    }

    // MARK: - Selection

    /// The stage revealed when nothing is picked: the running round's, else the first stage
    /// with a round still to run, else Draft — the pickers that can still change something.
    static func defaultSection(_ rows: [Row]) -> RoundsSection {
        if let live = rows.flatMap(\.chips).first(where: { $0.progress == .live }) { return live.section }
        if let open = rows.first(where: { $0.chips.contains { $0.progress == .planned } }) { return open.section }
        return rows.first?.section ?? .draft
    }

    /// Clicking a chip: picks it; clicking the picked chip again leaves its stage revealed with
    /// no chip picked. Clicking a stage's name reveals the stage alone.
    static func select(_ current: Selection?, chip key: RoundKey) -> Selection {
        current?.round == key ? Selection(section: .of(key.stage), round: nil) : .round(key)
    }

    /// The round a checkpoint id on `tape` is — the main view selects by checkpoint, the
    /// inspector by round.
    static func key(checkpoint id: Int, in tape: Tape) -> RoundKey? {
        tape.checkpoints.first { $0.id == id }.map { RoundKey(stage: $0.stage, round: $0.round) }
    }

    /// The inspector's pick when the main view moves its plan to a round (a card, the board,
    /// ⌘[): that round's chip — nil checkpoint meaning the head, which the main view follows.
    /// nil when the tape has no such round, so the pick is left as it was.
    static func selection(forPlanCheckpoint id: Int?, in tape: Tape) -> Selection? {
        guard let cp = id.flatMap({ id in tape.checkpoints.first { $0.id == id } }) ?? tape.head else { return nil }
        return .round(RoundKey(stage: cp.stage, round: cp.round))
    }

    /// Where a chip picked in the inspector takes the main view: a round that ran shows its
    /// checkpoint (nil checkpoint = follow the head, the main view's rule for the newest round);
    /// the running round, the live card; a round still to run, nowhere — the main view has
    /// nothing of it to show.
    enum MainTarget: Equatable {
        case checkpoint(Int?)
        case live
        case none
    }

    static func mainTarget(for key: RoundKey, rows: [Row], tape: Tape?) -> MainTarget {
        guard let chip = rows.flatMap(\.chips).first(where: { $0.key == key }) else { return .none }
        switch chip.progress {
        case .live: return .live
        case .planned: return .none
        case .done:
            guard let id = chip.checkpointID else { return .none }
            return .checkpoint(id == tape?.head?.id ? nil : id)
        }
    }
}
