import IntakeKit

/// The commands `IntakeService.send` folds into the published tape ahead of the runner, so a
/// click shows in its own main-actor turn. Without it the board moved only once the runner had
/// read `commands.jsonl` (its watcher polls every second, or it had to be spawned first) AND
/// the service's next tick had re-read `tape.json` (every 500 ms): 0.4–1.3 s measured for a
/// +/− on a running tape, and a different wait every click — "queued until the next repaint".
///
/// Never written anywhere: `tape.json` stays the runner's alone. A command stays in the overlay
/// only until a tape read acks it (`ackedCommandSeq`), and every read before that is shown with
/// the rest replayed on top — through the runner's own fold, `TapePlanner.apply`, in seq order —
/// so a read taken before the runner got to them can't drag the board back, and once the runner
/// has them all the board is its tape exactly: a trim it clamped differently (a round started in
/// between) converges on its answer, with nothing of the guess left behind.
enum TapeOverlay {
    /// The commands whose effect on the tape is decided by `TapePlanner.apply` alone, so folding
    /// them here can't disagree with the runner. `.stop` is the runner's own (it also ends the
    /// round, and its "Stopping…" is `HaltRequest`'s); notes have the notes rail's own
    /// optimistic copy; a plan edit is a file, not tape state.
    static func folds(_ command: TapeCommand) -> Bool {
        switch command {
        case .step, .nextMajor, .toReview, .pause, .extend, .trim: true
        case .stop, .note, .removeNote, .editPlan: false
        }
    }

    /// `pending` less the commands `tape` has already folded in.
    static func unconsumed(_ pending: [CommandEnvelope], by tape: Tape) -> [CommandEnvelope] {
        pending.filter { $0.seq > tape.ackedCommandSeq }
    }

    /// `tape` with `pending` applied in order, as the runner will apply them. `ackedCommandSeq` is
    /// left alone: an ack is the runner's to give, and `HaltRequest` waits on it.
    static func applying(_ pending: [CommandEnvelope], to tape: Tape, config: RoundConfig?) -> Tape {
        pending.reduce(into: tape) { TapePlanner.apply($1.command, to: &$0, config: config) }
    }
}
