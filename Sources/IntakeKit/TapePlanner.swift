import Foundation

/// Decides the round engine's next move. Stateless on purpose: every call recomputes the
/// full planned sequence from `config` plus the tape's `extraRefinement`/`extraPolish`, then
/// locates the head checkpoint's `(stage, round)` within it and returns the successor. That
/// recomputation — rather than caching a plan the moment a tape starts — is what makes a
/// `.extend` issued mid-refine lengthen the stage and move its major checkpoint to the new
/// last round, while the same command issued after refine has already finished does nothing:
/// the head's position in the freshly rebuilt sequence is unchanged either way. A `.trim`
/// shortens the stage the same way, from the other end.
public enum TapePlanner {
    /// The full stage/round/major sequence a config (with the tape's current extensions)
    /// plans to run, ending at release review. Not part of the public interface — `next`
    /// is the only thing that needs it, expressed once so the ordering lives in one place.
    private static func sequence(config: RoundConfig, extraRefinement: Int, extraPolish: Int) -> [PlannedRound] {
        var seq: [PlannedRound] = [PlannedRound(stage: .draft, round: 0, major: true)]

        if config.synthesizer != nil {
            seq.append(PlannedRound(stage: .synthesis, round: 0, major: true))
        }

        let refineTotal = config.reviewer != nil ? config.refinementCap + extraRefinement : 0
        if refineTotal > 0 {
            for round in 1...refineTotal {
                seq.append(PlannedRound(stage: .refine, round: round, major: round == refineTotal))
            }
        }

        seq.append(PlannedRound(stage: .encode, round: 0, major: true))

        let polishTotal = config.polisher != nil ? config.polishCap + extraPolish : 0
        if polishTotal > 0 {
            for round in 1...polishTotal {
                seq.append(PlannedRound(stage: .polish, round: round, major: round == polishTotal))
            }
        }

        // Both rounds are seated by the polisher; planning them without one would run the tape
        // to encode and then pause on a seat a `.shaping` intake can no longer fill.
        if config.freshEyesAndDedup && config.polisher != nil {
            seq.append(PlannedRound(stage: .freshEyes, round: 0, major: false))
            seq.append(PlannedRound(stage: .dedup, round: 0, major: true))
        }

        return seq
    }

    /// The next round to run given what exists, or nil when the tape has reached release
    /// review.
    public static func next(after tape: Tape, config: RoundConfig) -> PlannedRound? {
        let seq = sequence(config: config, extraRefinement: tape.extraRefinement, extraPolish: tape.extraPolish)
        guard let head = tape.head else { return seq.first }
        // Match on (stage, round), not array position — an `.extend` that landed after `head`
        // ran only inserts rounds later in the same stage, so `head`'s tuple still identifies
        // the same slot in the rebuilt sequence and the walk resumes forward from there.
        guard let index = seq.firstIndex(where: { $0.stage == head.stage && $0.round == head.round }) else {
            // The config changed out from under an in-progress tape (e.g. `polishCap` edited
            // down below a round the head already ran) so `head` no longer appears in the
            // rebuilt sequence at all. There's no sound "next round" to resume with — guessing
            // one could replay or skip work — so this deliberately fails safe to release
            // review rather than guessing; a human looking at a stale tape is expected to
            // notice and decide, not have the runner push forward on a sequence that no
            // longer matches what already happened.
            return nil
        }
        let nextIndex = index + 1
        return nextIndex < seq.count ? seq[nextIndex] : nil
    }

    /// `(stage, round)` as the tape plans it NOW — nil when it isn't in the sequence. The runner
    /// takes a landing checkpoint's `major` from here rather than from the round as it was planned
    /// at its start: an extend or trim that landed mid-round moved the stage's last round, and the
    /// board (which replays this sequence) already shows the new one as the major stop.
    public static func planned(stage: Stage, round: Int, tape: Tape, config: RoundConfig) -> PlannedRound? {
        sequence(config: config, extraRefinement: tape.extraRefinement, extraPolish: tape.extraPolish)
            .first { $0.stage == stage && $0.round == round }
    }

    /// Whether stopping right after `checkpoint` satisfies `target`.
    public static func satisfies(_ target: TapeTarget, after checkpoint: Checkpoint, nextRound: PlannedRound?) -> Bool {
        switch target {
        case .none: true
        case .nextMinor: true
        case .nextMajor: checkpoint.major
        case .review: nextRound == nil
        }
    }

    /// Fold one command into the tape (target / pause / extend / trim / notes). `.stop` is
    /// handled by the runner, not here — folding it into the tape would race the runner's own
    /// shutdown write. `config` is needed only by `.trim`, to know how many rounds the stage
    /// plans; without it a trim is ignored rather than guessed at.
    public static func apply(_ c: TapeCommand, to tape: inout Tape, config: RoundConfig? = nil) {
        switch c {
        case .step:
            tape.target = .nextMinor
            clearTerminalStatus(&tape)
        case .nextMajor:
            tape.target = .nextMajor
            clearTerminalStatus(&tape)
        case .toReview:
            tape.target = .review
            clearTerminalStatus(&tape)
        case .pause:
            // The runner finishes the round already in flight, then stops on its own —
            // dropping the target to `.none` is the only signal it needs.
            tape.target = .none
        case .stop:
            break
        case .note(let note):
            tape.pendingNotes.append(note)
        case .removeNote(let id):
            // Only a pending note can be withdrawn: one a round already consumed is part of
            // that round's record, and the prompt it shaped can't be taken back.
            tape.pendingNotes.removeAll { $0.id == id }
        case .editPlan:
            // A file, not tape state: the runner writes it (`TapeStore.writeUserEdits`), since
            // this function only folds a command into the tape value.
            break
        case .extend(let stage, let by):
            switch stage {
            case .refine: tape.extraRefinement += by
            case .polish: tape.extraPolish += by
            default: break
            }
        case .trim(let stage, let by):
            guard let config, by > 0 else { return }
            trim(stage, by: by, tape: &tape, config: config)
        }
    }

    /// Takes up to `by` unstarted rounds off the end of `stage`. Never below the rounds already
    /// on the tape plus the one in flight: those are paid for, and a head missing from the
    /// rebuilt sequence would send `next` to release review. Trimming to exactly that count ends
    /// the stage after the current round (and makes it the major); to zero before the stage
    /// starts, skips it. Folded against the tape it is applied to, so the runner's watcher
    /// re-reading mid-round can't take away the round it is running.
    private static func trim(_ stage: Stage, by: Int, tape: inout Tape, config: RoundConfig) {
        let (cap, seated): (Int, Bool)
        switch stage {
        case .refine: (cap, seated) = (config.refinementCap, config.reviewer != nil)
        case .polish: (cap, seated) = (config.polishCap, config.polisher != nil)
        default: return
        }
        guard seated else { return }
        let extra = stage == .refine ? tape.extraRefinement : tape.extraPolish
        let ran = tape.checkpoints.filter { $0.stage == stage }.map(\.round).max() ?? 0
        let inFlight = tape.roundInProgress.flatMap { $0.stage == stage ? $0.round : nil } ?? 0
        let planned = max(0, cap + extra)
        let total = max(max(ran, inFlight), planned - by)
        guard total < planned else { return }
        if stage == .refine { tape.extraRefinement = total - cap } else { tape.extraPolish = total - cap }
    }

    /// A fresh target only clears a *stopped-for-a-reason* status — `.paused`, `.stopped` or
    /// `.failed` — back to `.idle` so the runner picks it back up. `.running` and
    /// `.reachedReview` are left alone; they're not stuck, so there's nothing to clear.
    private static func clearTerminalStatus(_ tape: inout Tape) {
        switch tape.status {
        case .paused, .stopped, .failed: tape.status = .idle
        case .idle, .running, .reachedReview: break
        }
    }
}
