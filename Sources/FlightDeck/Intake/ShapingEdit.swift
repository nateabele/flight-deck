import IntakeKit

/// What the Rounds editor may still change once shaping has started, read off the tape. The
/// runner reads `intake.roundConfig` once per start (`IntakeRunner.drive`), so a config saved
/// while nothing runs applies from the next round on — but an agent whose stages have all run
/// would change nothing, and a cap below the rounds already run would drop the tape's head out
/// of the planned sequence, which sends `TapePlanner.next` straight to release review.
///
/// Derived from the checkpoints, not from the state of any one role: a stage is done once a
/// later stage has a checkpoint, or — for a stage that runs exactly once — once it has one of
/// its own. Refine and polish are sized by a cap, so their last planned round having run does
/// not end them: a raised cap or a + still adds rounds until a later stage runs.
struct ShapingEdit: Equatable {
    /// Every stage the tape has finished for good.
    let doneStages: Set<Stage>
    /// The tape's extend/trim counters (`Tape.extraRefinement`/`extraPolish`). The editor shows
    /// cap + counter, the rounds the stage will actually run, and saves a cap that keeps the
    /// counter as it is — the counter belongs to `tape.json`, which the runner owns.
    let extraRefinement: Int
    let extraPolish: Int
    /// The highest round of each stage already on the tape.
    let refineRan: Int
    let polishRan: Int

    init(tape: Tape) {
        let ran = Set(tape.checkpoints.map(\.stage))
        let furthest = tape.checkpoints.map { BoardModel.rank($0.stage) }.max() ?? -1
        doneStages = Set(Stage.allCases.filter { stage in
            BoardModel.rank(stage) < furthest || (!Self.capSized.contains(stage) && ran.contains(stage))
        })
        extraRefinement = tape.extraRefinement
        extraPolish = tape.extraPolish
        refineRan = tape.checkpoints.filter { $0.stage == .refine }.map(\.round).max() ?? 0
        polishRan = tape.checkpoints.filter { $0.stage == .polish }.map(\.round).max() ?? 0
    }

    /// The stages whose length a cap sets (`TapePlanner.sequence`).
    private static let capSized: Set<Stage> = [.refine, .polish]

    /// The stages each role is an agent in (`RoundExecutor.run`): the reviewers and the
    /// integrator work only in refine; the polisher runs polish, fresh eyes and dedup.
    static func stages(of role: SlotKeyPath) -> [Stage] {
        switch role {
        case .drafter: [.draft]
        case .synthesizer: [.synthesis]
        case .reviewer, .crossReviewer, .integrator: [.refine]
        case .encoder: [.encode]
        case .polisher: [.polish, .freshEyes, .dedup]
        }
    }

    /// Whether every stage `role` works in has run — the row shows disabled, "already ran".
    func isLocked(_ role: SlotKeyPath) -> Bool { Self.stages(of: role).allSatisfy(doneStages.contains) }

    var refineDone: Bool { doneStages.contains(.refine) }
    var polishDone: Bool { doneStages.contains(.polish) }
    /// Turning fresh eyes + dedup off after fresh eyes ran would drop the head out of the
    /// sequence; on, after it, would plan rounds behind the head that never run.
    var freshEyesDone: Bool { doneStages.contains(.freshEyes) }

    // MARK: Caps

    func refinementTotal(_ config: RoundConfig) -> Int { config.refinementCap + extraRefinement }
    func polishTotal(_ config: RoundConfig) -> Int { config.polishCap + extraPolish }

    /// The fewest rounds the stage can be set to: those already run (they are paid for, and the
    /// head must stay in the sequence), and no fewer than the counter, below which the cap would
    /// go negative. A + pressed earlier is taken back with −, not here.
    var refinementFloor: Int { max(refineRan, extraRefinement, 0) }
    var polishFloor: Int { max(polishRan, extraPolish, 0) }

    /// The config whose cap makes refine run `total` rounds with the counter left as it is —
    /// so a total of 5 over one + saves cap 4, and the planner runs 5, not 6.
    func settingRefinementTotal(_ config: RoundConfig, to total: Int) -> RoundConfig {
        RoundConfigEditor.setting(config) { $0.refinementCap = max(total, refinementFloor) - extraRefinement }
    }

    func settingPolishTotal(_ config: RoundConfig, to total: Int) -> RoundConfig {
        RoundConfigEditor.setting(config) { $0.polishCap = max(total, polishFloor) - extraPolish }
    }

    // MARK: Refusals

    /// Why `edited` can't replace `saved` on this tape, or nil when it can. The editor never
    /// offers these changes; the service checks anyway, because a config reaches it from a
    /// draft held across a run, and a write here changes what the next round runs.
    func refusal(from saved: RoundConfig, to edited: RoundConfig) -> String? {
        if doneStages.contains(.draft), saved.drafters != edited.drafters { return Self.ran("drafter") }
        if doneStages.contains(.synthesis), saved.synthesizer != edited.synthesizer { return Self.ran("synthesizer") }
        if refineDone {
            if saved.reviewer != edited.reviewer { return Self.ran("reviewer") }
            if saved.crossReviewer != edited.crossReviewer || saved.crossCheck != edited.crossCheck {
                return Self.ran("cross-check agent")
            }
            if saved.integrator != edited.integrator { return Self.ran("integrator") }
            if saved.refinementCap != edited.refinementCap { return "Refinement already ran, so its rounds can't change." }
        }
        if doneStages.contains(.encode), saved.encoder != edited.encoder { return Self.ran("encoder") }
        if isLocked(.polisher), saved.polisher != edited.polisher { return Self.ran("polisher") }
        if polishDone, saved.polishCap != edited.polishCap { return "Polish already ran, so its rounds can't change." }
        if freshEyesDone, saved.freshEyesAndDedup != edited.freshEyesAndDedup {
            return "Fresh eyes already ran, so it can't be turned on or off."
        }
        if edited.refinementCap < 0 || edited.polishCap < 0 { return "A stage can't run fewer than zero rounds." }
        if refinementTotal(edited) < refineRan { return "Refinement has already run \(Self.rounds(refineRan))." }
        if polishTotal(edited) < polishRan { return "Polish has already run \(Self.rounds(polishRan))." }
        return nil
    }

    private static func ran(_ role: String) -> String { "The \(role) already ran, so it can't change." }
    private static func rounds(_ n: Int) -> String { n == 1 ? "1 round" : "\(n) rounds" }
}
