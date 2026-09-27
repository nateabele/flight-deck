import Foundation
import Darwin

/// Runs one intake's tape toward its target: folds in `commands.jsonl`, runs `RoundExecutor`
/// rounds with a command watcher alongside, and writes each checkpoint. Restartable by design —
/// everything it needs to resume is in `tape.json`, so the detached `flightdeck intake run`
/// process can die at any point and a fresh one picks up where it left off.
///
/// Reads `intake.json` but never writes it: the app owns that file, and a second writer in
/// another process would race it.
public struct IntakeRunner: Sendable {
    private let root: URL
    private let intakeID: UUID
    private let executor: RoundExecutor
    private let environment: [String: String]
    private let pollInterval: Duration
    private let now: @Sendable () -> Date

    public init(root: URL, intakeID: UUID, executor: RoundExecutor, environment: [String: String],
                pollInterval: Duration = .seconds(1), now: @escaping @Sendable () -> Date = Date.init) {
        self.root = root
        self.intakeID = intakeID
        self.executor = executor
        self.environment = environment
        self.pollInterval = pollInterval
        self.now = now
    }

    /// Runs until the target is satisfied, the tape pauses/fails/stops, or reaches review.
    /// Returns the final status. The tape write that records it is the last thing this does, so
    /// a watcher that sees a terminal status can treat the runner as gone.
    public func run() async -> RunnerStatus {
        let intakes = IntakeStore(root: root)
        let keeper = TapeKeeper(store: TapeStore(intakeDirectory: intakes.directory(for: intakeID)), now: now)

        let intake: Intake
        let config: RoundConfig
        do {
            intake = try intakes.load(id: intakeID)
            guard let c = intake.roundConfig else { throw MissingConfig() }
            config = c
        } catch {
            let detail = error is MissingConfig ? "the intake has no round config" : "could not read the intake: \(error)"
            return await keeper.finish(.failed, diagnosis: Diagnosis(category: .harnessError, detail: detail,
                                                                     action: "Choose a fidelity for the intake, then start it again."))
        }

        await keeper.adopt(pid: getpid())
        var rerunNote = await keeper.recoverInterruptedRound()
        while true {
            if await keeper.applyCommands() { return await keeper.finish(.stopped) }
            let tape = await keeper.tape
            switch tape.status {
            // Only a fresh ▶/⏭/⏩ clears these (`TapePlanner.apply`); a runner relaunched
            // without one must not quietly retry a failure or undo a ⏹.
            case .failed, .stopped: return await keeper.finish(tape.status)
            case .idle, .running, .paused, .reachedReview: break
            }
            guard let next = TapePlanner.next(after: tape, config: config) else { return await keeper.finish(.reachedReview) }
            // A reached target is spent (set to `.none`) in the same write as the checkpoint that
            // reached it, so `.none` is the only "stop here" signal and it survives a restart.
            if tape.target == .none { return await keeper.finish(tape.checkpoints.isEmpty ? .idle : .paused) }

            let started = await keeper.startRound(next)
            let inputs = RoundInputs(intake: intake, config: config, tape: started, store: keeper.store,
                                     project: URL(fileURLWithPath: intake.projectPath, isDirectory: true),
                                     environment: environment, now: now)
            let executor = self.executor
            let round = Task { try await executor.run(next, inputs) }
            let watcher = Task { [pollInterval] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: pollInterval)
                    if Task.isCancelled { return }
                    // The heartbeat rides on every poll, so it keeps moving through a round of
                    // any length — the app calls a runner dead once it is 10 s stale.
                    if await keeper.applyCommands(heartbeat: true) {
                        round.cancel()
                        return
                    }
                }
            }
            let result = await round.result
            watcher.cancel()
            await watcher.value

            switch result {
            case .failure:
                // `RoundExecutor.run` throws only `CancellationError`, and only ⏹ cancels it.
                // Its children are already killed (`CommandRunner`'s process-group cancel), and
                // nothing from the round is checkpointed.
                return await keeper.finish(.stopped)
            case .success(.paused(let diagnosis, _)):
                return await keeper.finish(.failed, diagnosis: diagnosis)
            case .success(.checkpoint(var cp, let files)):
                if rerunNote {
                    cp.record.note = ["rerun after interruption", cp.record.note].compactMap { $0 }.joined(separator: "\n\n")
                }
                do {
                    try await keeper.writeCheckpoint(cp, files: files, config: config)
                } catch {
                    return await keeper.finish(.failed, diagnosis: Diagnosis(
                        category: .harnessError, detail: "Could not save checkpoint \(cp.id): \(error)",
                        action: "Check the disk has space and the intake folder is writable, then retry the round."))
                }
                rerunNote = false
                // A ⏹ that landed after the round had already finished: the work is kept (it
                // completed cleanly), but nothing further runs.
                if await keeper.stopRequested { return await keeper.finish(.stopped) }
            }
        }
    }

    private struct MissingConfig: Error {}
}

/// The one place `tape.json` is mutated and saved. The main loop and the command watcher run
/// concurrently; with each holding its own copy, whichever saved second would silently undo
/// the other's write (an acked command replayed, a heartbeat rolled back). Every change here
/// is applied to the in-memory tape and saved from it, so a save is never of a stale copy.
private actor TapeKeeper {
    let store: TapeStore
    private let now: @Sendable () -> Date
    private(set) var tape: Tape
    private(set) var stopRequested = false

    init(store: TapeStore, now: @escaping @Sendable () -> Date) {
        self.store = store
        self.now = now
        self.tape = store.loadTape()
    }

    func adopt(pid: Int32) {
        tape.runnerPID = pid
        tape.heartbeat = now()
        save()
    }

    /// A tape with `roundInProgress` set means the previous runner died mid-round. Its children
    /// may still be running — they were each their own process-group leader, so a parent's
    /// death didn't take them with it — and their output can't be trusted, so they are killed
    /// and the round reruns from scratch. Returns whether there was such a round.
    func recoverInterruptedRound() -> Bool {
        guard let round = tape.roundInProgress else { return false }
        let prefix = "\(round.stage.rawValue)-\(round.round)-"
        let runs = store.intakeDirectory.appendingPathComponent("runs", isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: runs.path)) ?? []
        for name in names where name.hasPrefix(prefix) {
            guard let data = try? Data(contentsOf: runs.appendingPathComponent(name).appendingPathComponent("run.json")),
                  let run = try? IntakeJSON.decoder.decode(RunRecord.self, from: data),
                  run.finished == nil, let pid = run.pid, kill(pid, 0) == 0 else { continue }
            // Accepted risk: after a reboot (or a very long outage) this pid may belong to an
            // unrelated process. `killpg` narrows it — it only lands if that pid now leads a
            // process group — but can't rule it out; the alternative, leaving a live harness
            // child editing `work/` under the rerun, is the worse failure.
            killpg(pid, SIGKILL)
        }
        tape.roundInProgress = nil
        save()
        return true
    }

    /// Folds every command after `ackedCommandSeq` into the tape and acks it, in one save.
    /// Returns true when one of them was ⏹ — the caller decides what stopping means where it is.
    func applyCommands(heartbeat: Bool = false) -> Bool {
        let fresh = store.commands(after: tape.ackedCommandSeq)
        var stop = false
        for envelope in fresh {
            switch envelope.command {
            case .stop:
                stop = true
                tape.target = .none
            case .step, .nextMajor, .toReview:
                // ⏹ then a fresh ▶ in the same batch: the later command wins.
                stop = false
                TapePlanner.apply(envelope.command, to: &tape)
            case .pause, .annotate, .extend:
                TapePlanner.apply(envelope.command, to: &tape)
            }
            tape.ackedCommandSeq = envelope.seq
        }
        if stop { stopRequested = true }
        if heartbeat { tape.heartbeat = now() }
        if heartbeat || !fresh.isEmpty { save() }
        return stop
    }

    func startRound(_ next: PlannedRound) -> Tape {
        tape.status = .running
        tape.pauseDiagnosis = nil
        tape.roundInProgress = next
        tape.heartbeat = now()
        save()
        return tape
    }

    /// Appends the checkpoint, consumes the annotations the round used, clears
    /// `roundInProgress` and spends a reached target — all in `writeCheckpoint`'s single tape
    /// save, so a crash leaves either the whole round recorded or none of it.
    func writeCheckpoint(_ cp: Checkpoint, files: [String: Data], config: RoundConfig) throws {
        var next = tape
        for used in cp.record.annotations {
            if let i = next.pendingAnnotations.firstIndex(of: used) { next.pendingAnnotations.remove(at: i) }
        }
        next.roundInProgress = nil
        next.heartbeat = now()
        var after = next
        after.checkpoints.append(cp)
        if TapePlanner.satisfies(next.target, after: cp, nextRound: TapePlanner.next(after: after, config: config)) {
            next.target = .none
        }
        try store.writeCheckpoint(cp, files: files, into: &next)
        tape = next
    }

    /// The runner's last write: the final status, with `runnerPID` and `heartbeat` cleared so
    /// nothing reads an exited runner as alive.
    func finish(_ status: RunnerStatus, diagnosis: Diagnosis? = nil) -> RunnerStatus {
        tape.status = status
        if let diagnosis { tape.pauseDiagnosis = diagnosis }
        tape.roundInProgress = nil
        tape.runnerPID = nil
        tape.heartbeat = nil
        save()
        return status
    }

    /// Best effort: a failed save here (a full disk, a read-only folder) must not crash the
    /// runner — the checkpoint save, the one that matters, reports its failure itself.
    private func save() { try? store.saveTape(tape) }
}
