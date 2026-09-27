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
    private let hooks: Hooks

    /// Test seams, internal on purpose. Each exists because the moment it exposes can't be
    /// observed from outside without racing the runner: recovery's kill (ordering "adopt"
    /// against "recover"), the instant before the final save (a command landing as the runner
    /// exits), and the checkpoint's own tape save (failing it alone, after the files landed).
    struct Hooks: Sendable {
        var killGroup: @Sendable (Int32) -> Void = { _ = killpg($0, SIGKILL) }
        var beforeCheckpointSave: @Sendable () throws -> Void = {}
        var beforeFinalSave: @Sendable () -> Void = {}
    }

    public init(root: URL, intakeID: UUID, executor: RoundExecutor, environment: [String: String],
                pollInterval: Duration = .seconds(1), now: @escaping @Sendable () -> Date = Date.init) {
        self.init(root: root, intakeID: intakeID, executor: executor, environment: environment,
                  pollInterval: pollInterval, now: now, hooks: Hooks())
    }

    init(root: URL, intakeID: UUID, executor: RoundExecutor, environment: [String: String],
         pollInterval: Duration, now: @escaping @Sendable () -> Date, hooks: Hooks) {
        self.root = root
        self.intakeID = intakeID
        self.executor = executor
        self.environment = environment
        self.pollInterval = pollInterval
        self.now = now
        self.hooks = hooks
    }

    /// Runs until the target is satisfied, the tape pauses/fails/stops, or reaches review.
    /// Returns the final status. The tape write that records it is the last thing this does, so
    /// a watcher that sees a terminal status can treat the runner as gone.
    ///
    /// - One runner per intake: an exclusive `flock` on `<intake>/runner.lock` is taken before
    ///   anything else. A runner that finds it held returns the tape's current status (the
    ///   holder's) without writing anything — a double spawn must not have two loops writing
    ///   one tape, nor the loser's exit clearing the winner's heartbeat.
    /// - No `intake.json` at all returns `.failed` without touching disk: adopting would create
    ///   the directory, and a `tape.json`, for an intake that doesn't exist.
    /// - Cancelling the calling task cancels the round (its children are killed) and ends
    ///   `.stopped`.
    public func run() async -> RunnerStatus {
        let intakes = IntakeStore(root: root)
        let directory = intakes.directory(for: intakeID)
        guard FileManager.default.fileExists(atPath: directory.appendingPathComponent("intake.json").path) else {
            return .failed
        }
        let store = TapeStore(intakeDirectory: directory)
        guard let lock = RunnerLock(directory: directory) else { return store.loadTape().status }
        // Loaded under the lock, so it's never a copy another runner is still writing.
        let keeper = TapeKeeper(store: store, now: now, hooks: hooks)
        var (status, final) = await drive(keeper, intakes)
        while !final {
            // A command appended after the loop's last read but before the final save is stranded:
            // the app saw a live heartbeat and didn't spawn. Re-check AFTER unlocking, so a
            // command that lands later still finds either us here or a fresh runner the app spawns
            // on seeing the cleared heartbeat — which can take the lock we just dropped.
            lock.release()
            let acked = await keeper.tape.ackedCommandSeq
            guard !Task.isCancelled, !store.commands(after: acked).isEmpty, lock.acquire() else { return status }
            await keeper.reload()
            (status, final) = await drive(keeper, intakes)
        }
        return status
    }

    /// One adopt → recover → rounds → final-save pass over the tape. `final` is set only for an
    /// unusable intake: it never reads a command, and no command can fix it, so re-driving on an
    /// unacked one would spin forever.
    private func drive(_ keeper: TapeKeeper, _ intakes: IntakeStore) async -> (status: RunnerStatus, final: Bool) {
        // The FIRST tape write, before anything else reads or changes state: the app treats a
        // live runner socket without a fresh heartbeat as suspect, so a runner busy recovering
        // (or failing on a bad intake) must already look like the tape's owner.
        await keeper.adopt(pid: getpid())

        let intake: Intake
        let config: RoundConfig
        do {
            intake = try intakes.load(id: intakeID)
            guard let c = intake.roundConfig else { throw MissingConfig() }
            config = c
        } catch {
            let detail = error is MissingConfig ? "the intake has no round config" : "could not read the intake: \(error)"
            return (await keeper.finish(.failed, diagnosis: Diagnosis(category: .harnessError, detail: detail,
                                                                      action: "Choose a fidelity for the intake, then start it again.")),
                    true)
        }
        return (await rounds(keeper, intake: intake, config: config), false)
    }

    /// Recovery, then rounds until something ends the pass; always returns via `finish`.
    private func rounds(_ keeper: TapeKeeper, intake: Intake, config: RoundConfig) async -> RunnerStatus {
        var rerunNote = await keeper.recoverInterruptedRound()
        while true {
            if Task.isCancelled { return await keeper.finish(.stopped) }
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
            // Both are unstructured tasks, so cancelling `run()`'s task wouldn't reach them on
            // its own — the round's children would outlive a runner told to shut down.
            let result = await withTaskCancellationHandler {
                await round.result
            } onCancel: {
                round.cancel()
                watcher.cancel()
            }
            watcher.cancel()
            await watcher.value

            switch result {
            case .failure:
                // `RoundExecutor.run` throws only `CancellationError`: ⏹, or `run()` itself
                // cancelled. Its children are already killed (`CommandRunner`'s process-group
                // cancel), and nothing from the round is checkpointed.
                return await keeper.finish(.stopped)
            case .success(.paused(let diagnosis, _)):
                // A child killed by ⏹ can surface as a failed seat rather than a cancellation;
                // that's still the human's stop, not a failure to diagnose.
                if await keeper.stopRequested || Task.isCancelled { return await keeper.finish(.stopped) }
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
    private let hooks: IntakeRunner.Hooks
    private(set) var tape: Tape
    private(set) var stopRequested = false

    init(store: TapeStore, now: @escaping @Sendable () -> Date, hooks: IntakeRunner.Hooks) {
        self.store = store
        self.now = now
        self.hooks = hooks
        self.tape = store.loadTape()
    }

    /// Re-reads the tape after the lock was dropped and retaken — another runner may have
    /// held it in between, so the in-memory copy can't be trusted any more.
    func reload() {
        tape = store.loadTape()
    }

    func adopt(pid: Int32) {
        stopRequested = false
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
            hooks.killGroup(pid)
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
        try store.writeCheckpoint(cp, files: files, into: &next, beforeSave: hooks.beforeCheckpointSave)
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
        hooks.beforeFinalSave()
        save()
        return status
    }

    /// Best effort: a failed save here (a full disk, a read-only folder) must not crash the
    /// runner — the checkpoint save, the one that matters, reports its failure itself.
    private func save() { try? store.saveTape(tape) }
}

/// The exclusive, non-blocking `flock` on `<intake>/runner.lock` that makes a runner the tape's
/// only writer. `flock` rather than a pid file: the kernel drops it when the process dies, so
/// a crashed runner never leaves a stale lock behind for its restart to second-guess.
private final class RunnerLock: @unchecked Sendable {
    private let fd: Int32

    /// Nil when another runner holds it — or when the lock file can't even be opened, which
    /// stands aside the same way: without the lock, writing the tape isn't safe.
    init?(directory: URL) {
        fd = open(directory.appendingPathComponent("runner.lock").path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        guard fd >= 0, acquire() else { return nil }
    }

    func acquire() -> Bool { flock(fd, LOCK_EX | LOCK_NB) == 0 }
    func release() { flock(fd, LOCK_UN) }
    deinit { if fd >= 0 { close(fd) } }
}
