import Foundation
#if canImport(Glibc)
import Glibc
#endif

// The host's runner (spec §6.1–§6.3): one delegated command per run, in its own process group,
// with its output spooled so the run outlives the controller that started it.
//
// Lifecycle of a run:
//   queued(.screen)   waiting for the single screen lease (screen runs only)
//   queued(.slot)     waiting for `acquire` to hand over a checkout slot
//   running           spawned; output flows into the spool
//   finishing         the leader exited: leftovers in its group are killed, output drained,
//                     a service's `down` command run, artifacts captured, slot released
//   exited / died     terminal; `died` is a service that ended without being asked to
//   failed            never ran (preflight, subdir, spawn or acquire failure)
//
// Blocking work (waitpid, draining pipes, the down command) runs on a dedicated thread per
// run, never on Swift's cooperative pool, so a hundred long runs cannot starve the host's
// async code.
//
// A run never outlives hostd. Each leads its own process group, so neither launchd's stop nor
// a crash reaches it: hostd's SIGTERM path calls `shutdown`, and a running run records its
// group in `runs/<id>/pgid`, which the next `Runner` kills if a crashed hostd left it alive.
// Otherwise the next hostd hands the run's slot to a new run while the old one still writes
// into it.

/// The escalation clock, injected so tests can step through the 10 s graces instantly.
public protocol RunClock: Sendable {
    func sleep(seconds: Double) async
}

public struct SystemRunClock: RunClock {
    public init() {}
    public func sleep(seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}

public enum RunnerError: Error, Equatable, CustomStringConvertible {
    case unknownRun(String)
    /// The CLI's subdirectory resolves outside the checkout (`..`, absolute, or a symlink).
    case subdirEscapes(String)
    /// The CLI's subdirectory does not exist in the checkout.
    case missingSubdir(String)
    case screenUnsupported
    case noConsoleUser
    case screenLocked
    case spawnFailed(Int32)
    /// hostd is stopping (`shutdown`); the run never started.
    case shuttingDown

    public var description: String {
        switch self {
        case .unknownRun(let id): return "no run \(id) on this host"
        case .subdirEscapes(let s): return "working directory \(s) is outside the checkout"
        case .missingSubdir(let s): return "working directory \(s) does not exist in the synced checkout; is it ignored? try --include"
        case .screenUnsupported: return "screen runs are not supported on this host"
        case .noConsoleUser: return "nobody is logged in at the host's console; log in and retry"
        case .screenLocked: return "the host's screen is locked; unlock it and retry"
        case .spawnFailed(let e): return "could not start the command (errno \(e))"
        case .shuttingDown: return "the host is shutting down; retry once it is back"
        }
    }
}

public enum RunPhase: Sendable, Equatable {
    case queued(WaitReason)
    case running
    case exited(RunExit)
    /// A service that ended without `down` or `cancel`.
    case died(RunExit)
    case failed(String)

    var isTerminal: Bool {
        switch self {
        case .queued, .running: return false
        case .exited, .died, .failed: return true
        }
    }
}

/// What happens to a run's checkout slot when it ends, injected because the slot belongs to
/// `WorkspaceStore` (`Workspace`). Both run before the run reports its exit, and `atExit` runs
/// before `release`: once the slot is released the next run's checkout wipes the tree, so a
/// result commit or an artifact taken after that would capture someone else's files.
public struct RunLifecycle: Sendable {
    public var atExit: @Sendable (_ lease: CheckoutLease, _ runID: String, _ spec: RunSpec) async throws -> Void
    public var release: @Sendable (_ lease: CheckoutLease) async -> Void

    public init(atExit: @escaping @Sendable (CheckoutLease, String, RunSpec) async throws -> Void,
                release: @escaping @Sendable (CheckoutLease) async -> Void) {
        self.atExit = atExit
        self.release = release
    }

    public static let none = RunLifecycle(atExit: { _, _, _ in }, release: { _ in })

    /// hostd's wiring: commit a run's changes as its result, capture its `fetch` artifacts,
    /// then release the slot. A service has no result commit: its tree is the user's
    /// long-lived checkout, not one command's output.
    public static func workspace(_ store: any WorkspaceStore) -> RunLifecycle {
        RunLifecycle(atExit: { lease, runID, spec in
            if !spec.service { _ = try await store.resultCommit(lease: lease, runID: runID) }
            if !spec.fetch.isEmpty {
                _ = try await store.captureArtifacts(lease: lease, runID: runID, globs: spec.fetch)
            }
        }, release: { lease in
            await store.release(lease)
        })
    }
}

public final class Runner: RunControlling, @unchecked Sendable {
    /// SIGINT → SIGTERM → SIGKILL spacing (§6.1).
    public static let escalationGrace: Double = 10
    /// How long `acquire` may take before the run reports it is waiting for a slot. A free
    /// slot is handed over in milliseconds; reporting every run as queued would make the CLI
    /// print "waiting for a slot" before every command.
    static let slotNoticeDelay: UInt64 = 500_000_000

    private let runsRoot: URL
    private let shell: String
    private let hostEnvironment: [String: String]
    private let clock: any RunClock
    private let power: any PowerAsserting
    private let console: any ConsoleSessionProbing
    private let screen: ScreenLease
    private let lifecycle: RunLifecycle
    private let spoolCap: Int64

    private let lock = NSLock()
    private var runs: [String: Run] = [:]
    private var nextNumber = 1
    /// This runner's start time (epoch milliseconds, base 36), the first half of every run id
    /// it issues. Ids are opaque, but they name spools, result refs and the controller's
    /// records, so a hostd that restarted at `r1` reused names whose old data was still around
    /// (Ruling 27). Milliseconds, so two runners in one process (tests) differ too.
    private let idPrefix = String(UInt64(Date().timeIntervalSince1970 * 1000), radix: 36)
    private var shuttingDown = false

    /// Finished runs kept for `events` and `ps`. Older ones are forgotten (their spool stays on
    /// disk until the day-old prune): unbounded, a hostd that runs for weeks grows without end.
    static let retainedFinishedRuns = 200
    /// Spools untouched for this long are deleted, at startup and at most hourly afterwards.
    static let spoolRetention: TimeInterval = 24 * 3600
    private var finishedOrder: [String] = []
    private var lastPrune = Date.distantPast
    var retainedRunCount: Int { lock.withLock { runs.count } }
    /// Test seam: runs before every spool append (a slow or failing disk).
    var appendHook: (@Sendable () throws -> Void)? {
        get { lock.withLock { _appendHook } }
        set { lock.withLock { _appendHook = newValue } }
    }
    private var _appendHook: (@Sendable () throws -> Void)?
    /// Test seam: runs as a run asks for its slot, with its id (a cancel landing just then).
    var acquireHook: (@Sendable (String) -> Void)? {
        get { lock.withLock { _acquireHook } }
        set { lock.withLock { _acquireHook = newValue } }
    }
    private var _acquireHook: (@Sendable (String) -> Void)?

    /// - Parameters:
    ///   - runsRoot: `runs/` under the host's state root; each run spools to `runs/<id>/`.
    ///   - shell: the host user's login shell (§6.1).
    ///   - hostEnvironment: the host's own environment, which every run inherits. The
    ///     controller's is never sent (§2.2), so this plus `RunSpec.env` is all a run sees.
    ///   - power, console: HostKitDarwin's `IOKitPowerAssertions` and `DarwinConsoleSession`
    ///     on a macOS host; HostKit itself only knows Linux's.
    public init(runsRoot: URL,
                shell: String = Runner.loginShell(),
                hostEnvironment: [String: String] = ProcessInfo.processInfo.environment,
                clock: any RunClock = SystemRunClock(),
                power: any PowerAsserting = PowerAssertion.platformDefault,
                console: any ConsoleSessionProbing = ConsoleSession.platformDefault,
                screen: ScreenLease = ScreenLease(),
                lifecycle: RunLifecycle = .none,
                spoolCap: Int64 = OutputSpool.defaultCap) {
        self.runsRoot = runsRoot
        self.shell = shell
        self.hostEnvironment = hostEnvironment
        self.clock = clock
        self.power = power
        self.console = console
        self.screen = screen
        self.lifecycle = lifecycle
        self.spoolCap = spoolCap
        screen.observe { [weak self] in self?.screenQueueChanged() }
        // Before anything can start: a slot is only safe to hand out once nothing a previous
        // hostd started still runs in it.
        killOrphanedGroups()
        pruneOldSpools()
    }

    /// `$SHELL` when set, else the passwd entry: hostd under launchd or systemd often has no
    /// `SHELL`, and falling straight to /bin/sh would skip the user's login profile (and with
    /// it their PATH, which is where xcodebuild and docker live).
    public static func loginShell() -> String {
        if let s = ProcessInfo.processInfo.environment["SHELL"], !s.isEmpty { return s }
        if let pw = getpwuid(getuid()), let sh = pw.pointee.pw_shell {
            let s = String(cString: sh)
            if !s.isEmpty { return s }
        }
        return "/bin/sh"
    }

    // MARK: - RunControlling

    public func start(_ spec: RunSpec, owner: LeaseHolderOwner,
                      acquire: @escaping @Sendable () async throws -> CheckoutLease) -> String {
        let (id, run, refused): (String, Run, Bool) = lock.withLock {
            var id: String
            repeat {
                id = "\(idPrefix)-r\(nextNumber)"
                nextNumber += 1
            } while runs[id] != nil || FileManager.default.fileExists(atPath: runsRoot.appendingPathComponent(id).path)
            let run = Run(id: id, spec: spec, owner: owner, acquire: acquire)
            runs[id] = run
            // Read with the registration, so `shutdown` either sees this run or it is refused.
            return (id, run, shuttingDown)
        }
        if refused {
            fail(run, RunnerError.shuttingDown)
            return id
        }

        do {
            run.spool = try OutputSpool(directory: runsRoot.appendingPathComponent(id), cap: spoolCap,
                                        markerStream: spec.pty ? .pty : .stderr)
        } catch {
            fail(run, error)
            return id
        }

        guard spec.screen else {
            beginAcquire(run)
            return id
        }
        // §7 step 6. The controller asks `screen.status` before syncing; this repeats the check
        // because the screen can lock between that answer and this request.
        let state = console.current()
        if !state.supported { fail(run, RunnerError.screenUnsupported); return id }
        if !state.consoleUser { fail(run, RunnerError.noConsoleUser); return id }
        if state.locked { fail(run, RunnerError.screenLocked); return id }

        update(run) { $0.phase = .queued(.screen) }
        _ = screen.request(id, holder: LeaseHolder(runID: id, session: owner.session)) { [weak self] in
            self?.screenGranted(run)
        }
        return id
    }

    public func events(runID: String, from offset: Int64) -> AsyncThrowingStream<RunEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { await self.pump(runID: runID, from: offset, into: continuation) }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func signal(runID: String, _ sig: Int32) throws {
        guard let run = lock.withLock({ runs[runID] }) else { throw RunnerError.unknownRun(runID) }
        let (phase, pgid) = lock.withLock { (run.phase, run.pgid) }
        switch phase {
        case .queued:
            // Nothing is running to receive it; a terminating signal means "never mind".
            if [SIGINT, SIGTERM, SIGKILL, SIGHUP].contains(sig) { cancel(runID: runID) }
        case .running:
            signalGroup(pgid, sig)
        case .exited, .died, .failed:
            break
        }
    }

    public func cancel(runID: String) {
        guard let run = lock.withLock({ runs[runID] }) else { return }
        let (phase, alreadyCancelling, launching): (RunPhase, Bool, Bool) = lock.withLock {
            defer { run.cancelRequested = true }
            return (run.phase, run.cancelRequested, run.launching)
        }
        switch phase {
        case .queued(.screen):
            terminate(run, .exited(.signal(SIGINT)))
        case .queued(.slot) where launching:
            // `launch` already holds the slot and reads `cancelRequested` as it publishes
            // `.running`, then escalates; ending the run here would orphan its process.
            break
        case .queued(.slot):
            // Ends now, not when `acquire` returns: a slot that never frees up would otherwise
            // leave a cancelled run "queued" forever. A slot that arrives later goes straight
            // back (`beginAcquire`).
            terminate(run, .exited(.signal(SIGINT)))
            lock.withLock { run.acquireTask }?.cancel()
        case .running:
            guard !alreadyCancelling else { return }
            escalate(run, [SIGINT, SIGTERM, SIGKILL])
        case .exited, .died, .failed:
            break
        }
    }

    public func down(runID: String) async throws {
        guard let run = lock.withLock({ runs[runID] }) else { throw RunnerError.unknownRun(runID) }
        let phase: RunPhase = lock.withLock {
            run.downRequested = true
            return run.phase
        }
        switch phase {
        case .queued: cancel(runID: runID)
        case .running: escalate(run, [SIGTERM, SIGKILL])
        case .exited, .died, .failed: return
        }
        await waitUntilTerminal(run)
    }

    public func liveRuns(controller: UUID) -> [String] {
        lock.withLock { runs.values.filter { $0.owner.controller == controller && !$0.phase.isTerminal }.map(\.id).sorted() }
    }

    /// Ends everything at once rather than through `cancel`'s 10 s INT→TERM→KILL ladder, which
    /// would outlast launchd's 20 s ExitTimeOut. A service is marked down, so `finish` runs its
    /// `down` command once its group is gone; queued runs end without starting.
    public func shutdown(grace: Double, deadline: Double) async {
        let began = Date()
        let live: [Run] = lock.withLock {
            shuttingDown = true
            return runs.values.filter { !$0.phase.isTerminal }
        }
        for run in live {
            let (phase, pgid): (RunPhase, pid_t) = lock.withLock {
                if run.spec.service { run.downRequested = true }
                return (run.phase, run.pgid)
            }
            switch phase {
            case .queued:
                cancel(runID: run.id)
            case .running:
                lock.withLock { run.cancelRequested = true }
                signalGroup(pgid, SIGTERM)
            case .exited, .died, .failed:
                break
            }
        }
        await waitEnded(live, until: began.addingTimeInterval(grace))
        for run in live {
            let (running, pgid) = lock.withLock { (run.phase == .running, run.pgid) }
            if running { signalGroup(pgid, SIGKILL) }
        }
        await waitEnded(live, until: began.addingTimeInterval(deadline))
    }

    private func waitEnded(_ runs: [Run], until deadline: Date) async {
        while Date() < deadline, lock.withLock({ runs.contains { !$0.phase.isTerminal } }) {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    // MARK: - Queries

    /// Who started the run. The host router scopes runs by controller with it (§A2): another
    /// controller's run answers `unknown_run`.
    public func owner(runID: String) -> LeaseHolderOwner? {
        lock.withLock { runs[runID]?.owner }
    }

    public func phase(runID: String) -> RunPhase? {
        lock.withLock { runs[runID]?.phase }
    }

    public func screenStatus() -> ScreenStatus {
        let state = console.current()
        return ScreenStatus(supported: state.supported, consoleUser: state.consoleUser, locked: state.locked,
                            holder: screen.holder, queued: screen.queued)
    }

    // MARK: - Queueing

    private func screenGranted(_ run: Run) {
        // Taken outside the runner lock: an IOKit call has no business under a lock every
        // `events` subscriber contends on.
        let display = power.hold(.displaySleep, reason: "Flight Deck screen run \(run.id)")
        let keep: Bool = lock.withLock {
            guard !run.phase.isTerminal, !run.cancelRequested else { return false }
            run.assertions.append(display)
            return true
        }
        guard keep else {
            display.release()
            screen.release(run.id)
            return
        }
        beginAcquire(run)
    }

    private func screenQueueChanged() {
        let queued = lock.withLock { runs.values.filter { $0.phase == .queued(.screen) } }
        for run in queued { update(run) { _ in } }
    }

    private func beginAcquire(_ run: Run) {
        acquireHook?(run.id)
        // The task is stored in the same critical section that publishes `.queued(.slot)`, so a
        // cancel that sees the phase always finds the task to cancel. A run already ended or
        // cancelled (a cancel landing between a screen grant and here) is left alone:
        // publishing `.queued(.slot)` over its exit would resurrect it and take a slot for it.
        var abandoned = false
        update(run) {
            guard !$0.phase.isTerminal, !$0.cancelRequested else {
                abandoned = !$0.phase.isTerminal
                return
            }
            $0.phase = .queued(.slot)
            $0.acquireTask = Task { [weak self] in
                let notice = Task { [weak self] in
                    try await Task.sleep(nanoseconds: Self.slotNoticeDelay)
                    self?.update(run) { $0.slotWaitVisible = true }
                }
                let result: Result<CheckoutLease, Error>
                do { result = .success(try await run.acquire()) } catch { result = .failure(error) }
                notice.cancel()
                guard let self else { return }
                switch result {
                case .success(let lease):
                    guard self.claimLaunch(run) else {
                        await self.lifecycle.release(lease)
                        self.terminate(run, .exited(.signal(SIGINT)))
                        return
                    }
                    self.launch(run, in: lease)
                case .failure where self.lock.withLock({ run.cancelRequested }):
                    self.terminate(run, .exited(.signal(SIGINT)))
                case .failure(let error):
                    self.fail(run, error)
                }
            }
        }
        if abandoned { terminate(run, .exited(.signal(SIGINT))) }
    }

    /// Commits the run to starting, unless a cancel got there first. Atomic with `cancel`'s
    /// read of `launching`, so exactly one of them owns ending the run.
    private func claimLaunch(_ run: Run) -> Bool {
        lock.withLock {
            guard !run.phase.isTerminal, !run.cancelRequested else { return false }
            run.launching = true
            return true
        }
    }

    // MARK: - Running

    private func launch(_ run: Run, in lease: CheckoutLease) {
        let spec = run.spec
        let process: SpawnedProcess
        let cwd: String
        do {
            cwd = try Self.workingDirectory(lease.path, spec.subdir)
            process = try Spawner.spawn(shell: shell, command: spec.command, cwd: cwd,
                                        env: hostEnvironment.merging(spec.env) { $1 },
                                        pty: spec.pty ? (spec.ptySize ?? TerminalSize(columns: 80, rows: 24)) : nil)
        } catch {
            Task { await lifecycle.release(lease) }
            fail(run, error)
            return
        }
        let idle = power.hold(.idleSleep, reason: "Flight Deck run \(run.id)")
        let pump = OutputPump(fds: process.fds) { [weak self] stream, data in
            self?.appendOutput(run, stream, data)
        }
        // Read in the same critical section that publishes `.running`: a cancel that set the
        // flag earlier saw `.queued` and left the group alone, so it is ours to escalate; one
        // that comes later sees `.running` and escalates itself.
        var cancelledWhileQueued = false
        update(run) {
            $0.lease = lease
            $0.pgid = process.pid
            $0.cwd = cwd
            $0.assertions.append(idle)
            $0.phase = .running
            cancelledWhileQueued = $0.cancelRequested
        }
        recordGroup(run.id, process.pid)
        pump.start()
        if cancelledWhileQueued { escalate(run, [SIGINT, SIGTERM, SIGKILL]) }

        let reaper = Thread { [weak self] in
            let status = Spawner.wait(process.pid)
            self?.finish(run, leader: status, pump: pump, ptySlave: process.ptySlave)
        }
        reaper.name = "flightdeck run \(run.id)"
        reaper.start()
    }

    /// On the run's reaper thread, after its leader exited.
    private func finish(_ run: Run, leader exit: RunExit, pump: OutputPump, ptySlave: Int32?) {
        let pgid = lock.withLock { run.pgid }
        // Anything left in the group is a leftover (a background job, a daemon that did not
        // setsid). It would hold the output pipe open, so the run never ends, and keep writing
        // into a checkout the next run is about to reuse.
        reapGroup(pgid)
        // Gone, so the record goes: a later hostd must never signal a pgid the kernel has
        // since handed to someone else.
        try? FileManager.default.removeItem(at: groupRecord(run.id))
        drain(pump)
        if let ptySlave { close(ptySlave) }

        let (spec, lease, cwd, downRequested, cancelRequested) = lock.withLock {
            (run.spec, run.lease, run.cwd, run.downRequested, run.cancelRequested)
        }
        if downRequested, let down = spec.downCommand, let cwd {
            runDownCommand(down, in: cwd, run: run)
        }
        if let lease {
            blocking {
                do {
                    try await self.lifecycle.atExit(lease, run.id, spec)
                } catch {
                    self.appendOutput(run, spec.pty ? .pty : .stderr,
                                      Data("flightdeck: collecting the run's results failed: \(error)\n".utf8))
                }
                await self.lifecycle.release(lease)
            }
        }
        let asked = downRequested || cancelRequested
        terminate(run, spec.service && !asked ? .died(exit) : .exited(exit))
    }

    /// TERM to whatever is left of the group, KILL if it outlives the grace. Waits on the
    /// group itself, not the output: a slow disk behind the spool is not a reason to kill.
    private func reapGroup(_ pgid: pid_t) {
        func gone(within seconds: Double) -> Bool {
            let deadline = Date().addingTimeInterval(seconds)
            while groupAlive(pgid) {
                if Date() >= deadline { return false }
                usleep(20_000)
            }
            return true
        }
        guard groupAlive(pgid) else { return }
        signalGroup(pgid, SIGTERM)
        if !gone(within: 2) {
            signalGroup(pgid, SIGKILL)
            _ = gone(within: 1)
        }
    }

    /// Reads the run's output to its end once its group is gone. What is still in the pipes is
    /// the run's tail and is always read; the pump ends at EOF, or at the first quiet 100 ms
    /// for a writer that escaped the group (setsid) and for a pty (which never reports EOF
    /// while hostd holds its slave). Returns only once the pump thread has exited, so nothing
    /// can be appended after the run reports its exit.
    private func drain(_ pump: OutputPump) {
        pump.finishWhenIdle()
        // Bounded only against an escapee that never stops writing.
        if !pump.waitDone(seconds: 60) {
            pump.stop()
            _ = pump.waitDone(seconds: .infinity)
        }
    }

    /// The recipe's `down` (§6.2), e.g. `docker compose down`, after the service's group has
    /// gone, in the same checkout and environment; its output joins the run's spool.
    private func runDownCommand(_ command: String, in cwd: String, run: Run) {
        guard let process = try? Spawner.spawn(shell: shell, command: command, cwd: cwd,
                                               env: hostEnvironment.merging(run.spec.env) { $1 }, pty: nil)
        else { return }
        let pump = OutputPump(fds: process.fds) { [weak self] stream, data in
            self?.appendOutput(run, stream, data)
        }
        pump.start()
        _ = Spawner.wait(process.pid)
        reapGroup(process.pid)
        drain(pump)
    }

    /// Sends `signals[0]` now and each next one after the grace, while the group lives.
    private func escalate(_ run: Run, _ signals: [Int32]) {
        let pgid = lock.withLock { run.pgid }
        Task { [weak self] in
            for (i, sig) in signals.enumerated() {
                guard let self else { return }
                if i > 0 { await self.clock.sleep(seconds: Self.escalationGrace) }
                // The group, not just the leader: a leader that died on SIGINT may leave
                // children that ignore it (a non-interactive shell's background jobs do).
                let done = self.lock.withLock { run.phase.isTerminal }
                guard !done, self.groupAlive(pgid) else { return }
                self.signalGroup(pgid, sig)
            }
        }
    }

    // MARK: - Events

    private func pump(runID: String, from offset: Int64,
                      into continuation: AsyncThrowingStream<RunEvent, Error>.Continuation) async {
        guard let run = lock.withLock({ runs[runID] }) else {
            continuation.finish(throwing: RunnerError.unknownRun(runID))
            return
        }
        var pos = max(offset, 0)
        var lastQueued: RunEvent?
        var sentStarted = false
        while !Task.isCancelled {
            let (generation, phase, visible, spool) = lock.withLock {
                (run.generation, run.phase, run.slotWaitVisible, run.spool)
            }

            // 1. Current state.
            switch phase {
            case .queued(.screen):
                // At least 1: in the instant between a grant and `.queued(.slot)` the position is 0.
                let ev = RunEvent.queued(position: max(1, screen.position(of: runID) ?? 1), on: .screen,
                                         holder: screen.holder)
                if ev != lastQueued { continuation.yield(ev); lastQueued = ev }
            case .queued(.slot) where visible:
                let ev = RunEvent.queued(position: 1, on: .slot, holder: nil)
                if ev != lastQueued { continuation.yield(ev); lastQueued = ev }
            case .running, .exited, .died:
                if !sentStarted, lock.withLock({ run.lease }) != nil {
                    continuation.yield(.started(runID: runID))
                    sentStarted = true
                }
            case .queued, .failed:
                break
            }

            // 2. Output from the offset. Nothing is appended after the phase turns terminal
            // (finish drains the pumps first), so a terminal snapshot means this reads it all.
            let chunks = (try? spool?.read(from: pos)) ?? []
            for chunk in chunks {
                continuation.yield(.output(stream: chunk.stream, offset: chunk.offset, data: chunk.data))
                pos = chunk.offset + Int64(chunk.data.count)
            }
            if !chunks.isEmpty { continue }

            // 3. The end.
            switch phase {
            case .exited(let e): continuation.yield(.exited(e)); continuation.finish(); return
            case .died(let e): continuation.yield(.serviceDied(e)); continuation.finish(); return
            case .failed:
                let failure: Error? = lock.withLock { run.failure }
                continuation.finish(throwing: failure ?? RunnerError.spawnFailed(0))
                return
            case .queued, .running:
                await waitForChange(run, after: generation)
            }
        }
        continuation.finish()
    }

    private func waitForChange(_ run: Run, after generation: Int) async {
        let key = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                let now: Bool = lock.withLock {
                    if run.generation != generation || Task.isCancelled { return true }
                    run.waiters[key] = cont
                    return false
                }
                if now { cont.resume() }
            }
        } onCancel: {
            lock.withLock { run.waiters.removeValue(forKey: key) }?.resume()
        }
    }

    private func waitUntilTerminal(_ run: Run) async {
        while true {
            let (generation, done) = lock.withLock { (run.generation, run.phase.isTerminal) }
            if done || Task.isCancelled { return }
            await waitForChange(run, after: generation)
        }
    }

    // MARK: - State

    /// Mutates under the lock, then wakes every subscriber.
    private func update(_ run: Run, _ change: (Run) -> Void) {
        let waiters: [CheckedContinuation<Void, Never>] = lock.withLock {
            change(run)
            run.generation += 1
            defer { run.waiters = [:] }
            return Array(run.waiters.values)
        }
        for w in waiters { w.resume() }
    }

    private func fail(_ run: Run, _ error: Error) {
        terminate(run, .failed("\(error)"), failure: error)
    }

    /// The one way a run ends. Every path goes through here so none can leak what the run
    /// held: the screen lease (a failed screen run would otherwise wedge every later one),
    /// its power assertions, or its spool's file handles (hostd's soft limit is 256 fds).
    /// The first terminal phase wins.
    private func terminate(_ run: Run, _ phase: RunPhase, failure: Error? = nil) {
        screen.release(run.id)   // a no-op unless the run holds or waits for it
        releaseAssertions(run)
        // Reset with the read: the marker is written once, here, and a second `terminate` (the
        // first terminal phase wins, but each caller still gets this far) must not repeat it.
        let (spool, lost, lostError) = lock.withLock {
            defer { run.lostBytes = 0 }
            return (run.spool, run.lostBytes, run.lostError)
        }
        if lost > 0 {
            _ = try? spool?.append(Self.lostMarker(lost, lostError), to: run.spec.pty ? .pty : .stderr)
        }
        spool?.closeHandles()
        var prune = false
        update(run) {
            guard !$0.phase.isTerminal else { return }
            $0.failure = failure
            $0.phase = phase
            // Retired in the same critical section that publishes the end, so the retention
            // cap holds the moment a subscriber sees the exit.
            finishedOrder.append($0.id)
            while finishedOrder.count > Self.retainedFinishedRuns {
                runs.removeValue(forKey: finishedOrder.removeFirst())
            }
            prune = Date().timeIntervalSince(lastPrune) > 3600
        }
        if prune { pruneOldSpools() }
    }

    // MARK: - Groups a previous hostd left

    private func groupRecord(_ runID: String) -> URL {
        runsRoot.appendingPathComponent(runID).appendingPathComponent("pgid")
    }

    /// `<pgid> <boot time>`: the boot time keeps a hostd after a reboot from signalling an
    /// unrelated group that happens to have the same id.
    private func recordGroup(_ runID: String, _ pgid: pid_t) {
        let boot = Self.bootTime().map(String.init) ?? "?"
        try? Data("\(pgid) \(boot)\n".utf8).write(to: groupRecord(runID))
    }

    /// At startup: every recorded group still alive belongs to a run whose hostd crashed (or
    /// was SIGKILLed past launchd's ExitTimeOut) before `shutdown` could end it. TERM to all,
    /// KILL to whatever is left after 2 s, and the run marked died in `runs/<id>/died`.
    private func killOrphanedGroups() {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: runsRoot.path) else { return }
        let boot = Self.bootTime()
        var orphans: [(dir: URL, pgid: pid_t)] = []
        for name in names {
            let record = groupRecord(name)
            guard let text = try? String(contentsOf: record, encoding: .utf8) else { continue }
            let fields = text.split(whereSeparator: \.isWhitespace)
            let pgid = fields.first.flatMap { pid_t($0) } ?? 0
            let recordedBoot = fields.dropFirst().first.flatMap { Int($0) }
            // Within a few seconds: both clocks derive boot time from the wall clock, which
            // NTP may have nudged in between.
            let sameBoot = boot != nil && recordedBoot != nil && abs(boot! - recordedBoot!) <= 10
            if sameBoot, groupAlive(pgid) {
                signalGroup(pgid, SIGTERM)
                orphans.append((runsRoot.appendingPathComponent(name), pgid))
            } else {
                try? fm.removeItem(at: record)
            }
        }
        guard !orphans.isEmpty else { return }
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline, orphans.contains(where: { groupAlive($0.pgid) }) { usleep(20_000) }
        for orphan in orphans {
            if groupAlive(orphan.pgid) { signalGroup(orphan.pgid, SIGKILL) }
            try? Data("hostd stopped without ending this run; its process group \(orphan.pgid) was killed at the next start\n".utf8)
                .write(to: orphan.dir.appendingPathComponent("died"))
            try? fm.removeItem(at: orphan.dir.appendingPathComponent("pgid"))
        }
    }

    /// When this machine booted, in seconds since 1970; nil if it cannot be read.
    static func bootTime() -> Int? {
        #if canImport(Glibc)
        guard let stat = try? String(contentsOfFile: "/proc/stat", encoding: .utf8) else { return nil }
        for line in stat.split(separator: "\n") where line.hasPrefix("btime ") {
            return Int(line.dropFirst(6).trimmingCharacters(in: .whitespaces))
        }
        return nil
        #else
        var tv = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &tv, &size, nil, 0) == 0 else { return nil }
        return Int(tv.tv_sec)
        #endif
    }

    // MARK: - Spools

    /// Internal for a test; otherwise at startup and at most hourly from `terminate`.
    func pruneOldSpools() {
        let fm = FileManager.default
        let cutoff = Date().addingTimeInterval(-Self.spoolRetention)
        let live: Set<String> = lock.withLock {
            lastPrune = Date()
            return Set(runs.values.filter { !$0.phase.isTerminal }.map(\.id))
        }
        guard let names = try? fm.contentsOfDirectory(atPath: runsRoot.path) else { return }
        var pruned: [String] = []
        for name in names where !live.contains(name) {
            let dir = runsRoot.appendingPathComponent(name)
            // The newest of the directory and its files: appending to a spool file does not
            // touch the directory's own mtime.
            let files = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
            let newest = ([dir] + files.map { dir.appendingPathComponent($0) })
                .compactMap { (try? fm.attributesOfItem(atPath: $0.path))?[.modificationDate] as? Date }
                .max() ?? .distantFuture
            if newest < cutoff, (try? fm.removeItem(at: dir)) != nil { pruned.append(name) }
        }
        // A retained run whose spool is gone is forgotten with it: kept, it would replay as a
        // run that printed nothing, and `logs` would show an empty run instead of "gone".
        lock.withLock {
            for id in pruned where runs[id]?.phase.isTerminal ?? false { runs[id] = nil }
            finishedOrder.removeAll { runs[$0] == nil }
        }
    }

    /// Spools `data`, never losing a failure silently: bytes that could not be written (a full
    /// disk) are counted, and the next write that succeeds is preceded by a marker saying so.
    private func appendOutput(_ run: Run, _ stream: RunOutputStream, _ data: Data) {
        let (spool, hook) = lock.withLock { (run.spool, _appendHook) }
        guard let spool else { return }
        do {
            try hook?()
            let (lost, why) = lock.withLock { (run.lostBytes, run.lostError) }
            if lost > 0 {
                try spool.append(Self.lostMarker(lost, why), to: stream)
                lock.withLock { run.lostBytes = 0 }
            }
            try spool.append(data, to: stream)
        } catch {
            lock.withLock {
                run.lostBytes += data.count
                run.lostError = "\(error)"
            }
        }
        update(run) { _ in }
    }

    private static func lostMarker(_ bytes: Int, _ why: String) -> Data {
        Data("\n[flightdeck: \(bytes) bytes of output lost writing the spool: \(why)]\n".utf8)
    }

    private func releaseAssertions(_ run: Run) {
        let held: [PowerAssertion] = lock.withLock {
            defer { run.assertions = [] }
            return run.assertions
        }
        for a in held { a.release() }
    }

    private func groupAlive(_ pgid: pid_t) -> Bool {
        pgid > 1 && kill(-pgid, 0) == 0
    }

    private func signalGroup(_ pgid: pid_t, _ sig: Int32) {
        // Never kill(0, …) or kill(-1, …): those reach hostd's own group, or every process.
        guard pgid > 1 else { return }
        kill(-pgid, sig)
    }

    /// The checkout plus the CLI's subdirectory, refusing anything that resolves outside the
    /// checkout: `..`, an absolute path, or a symlink a synced tree could carry. A run that
    /// started in `/` with the user's credentials would be a delegation escape.
    static func workingDirectory(_ root: URL, _ subdir: String) throws -> String {
        guard let rootReal = realPath(root.path) else { throw RunnerError.missingSubdir("") }
        if subdir.isEmpty || subdir == "." { return rootReal }
        guard !subdir.hasPrefix("/") else { throw RunnerError.subdirEscapes(subdir) }
        // `..` resolved by hand: `standardizedFileURL` also rewrites /private/var to /var on
        // Darwin, which would make every checkout under the temp dir look like an escape.
        var parts: [Substring] = []
        for part in subdir.split(separator: "/") where part != "." {
            if part == ".." {
                guard !parts.isEmpty else { throw RunnerError.subdirEscapes(subdir) }
                parts.removeLast()
            } else {
                parts.append(part)
            }
        }
        let lexical = ([Substring(rootReal)] + parts).joined(separator: "/")
        guard let real = realPath(lexical) else { throw RunnerError.missingSubdir(subdir) }
        guard real == rootReal || real.hasPrefix(rootReal + "/") else { throw RunnerError.subdirEscapes(subdir) }
        return real
    }

    /// realpath(3), not `resolvingSymlinksInPath`, which on Darwin turns /private/var into
    /// /var and would make a correct path look like an escape.
    private static func realPath(_ path: String) -> String? {
        guard let p = realpath(path, nil) else { return nil }
        defer { free(p) }
        return String(cString: p)
    }

    /// Runs async work to completion from a plain thread (never a cooperative-pool one).
    private func blocking(_ work: @escaping @Sendable () async -> Void) {
        let done = DispatchSemaphore(value: 0)
        Task {
            await work()
            done.signal()
        }
        done.wait()
    }
}

// MARK: - Per-run state (guarded by Runner.lock)

private final class Run: @unchecked Sendable {
    let id: String
    let spec: RunSpec
    let owner: LeaseHolderOwner
    let acquire: @Sendable () async throws -> CheckoutLease

    var spool: OutputSpool?
    var phase: RunPhase = .queued(.slot)
    var failure: Error?
    var slotWaitVisible = false
    var lease: CheckoutLease?
    var cwd: String?
    var pgid: pid_t = 0
    var launching = false
    var lostBytes = 0
    var lostError = ""
    var assertions: [PowerAssertion] = []
    var cancelRequested = false
    var downRequested = false
    var acquireTask: Task<Void, Never>?
    var generation = 0
    var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    init(id: String, spec: RunSpec, owner: LeaseHolderOwner, acquire: @escaping @Sendable () async throws -> CheckoutLease) {
        self.id = id
        self.spec = spec
        self.owner = owner
        self.acquire = acquire
    }
}

// MARK: - Output pump

/// One thread reading every output fd of a process until EOF, or until told to stop.
private final class OutputPump: @unchecked Sendable {
    private let lock = NSLock()
    private var fds: [(fd: Int32, stream: RunOutputStream)]
    private var stopRequested = false
    private var idleEnds = false
    private let done = DispatchSemaphore(value: 0)
    private var finished = false
    private let onData: @Sendable (RunOutputStream, Data) -> Void

    init(fds: [(Int32, RunOutputStream)], onData: @escaping @Sendable (RunOutputStream, Data) -> Void) {
        self.fds = fds.map { (fd: $0.0, stream: $0.1) }
        self.onData = onData
    }

    func start() {
        let t = Thread { [self] in run() }
        t.name = "flightdeck run output"
        t.start()
    }

    func stop() { lock.withLock { stopRequested = true } }

    /// Ends the pump at the first 100 ms with nothing to read, for a pty whose slave hostd
    /// still holds open (so the master never reports EOF).
    func finishWhenIdle() { lock.withLock { idleEnds = true } }

    /// True once every fd hit EOF (or the pump was stopped and has closed them).
    func waitDone(seconds: Double) -> Bool {
        if lock.withLock({ finished }) { return true }
        if seconds.isInfinite {
            done.wait()
        } else {
            guard done.wait(timeout: .now() + seconds) == .success else { return false }
        }
        lock.withLock { finished = true }
        return true
    }

    private func run() {
        var open = fds
        var buffer = [UInt8](repeating: 0, count: OutputSpool.maxChunk)
        // A 100 ms poll rather than an indefinite block, so `stop` is noticed promptly even
        // when an escaped process holds a pipe open and never writes.
        while !open.isEmpty, !lock.withLock({ stopRequested }) {
            var pfds = open.map { pollfd(fd: $0.fd, events: Int16(POLLIN), revents: 0) }
            let ready = poll(&pfds, nfds_t(pfds.count), 100)
            if ready < 0 && errno == EINTR { continue }
            if ready == 0 && lock.withLock({ idleEnds }) { break }
            if ready <= 0 { continue }
            var closed: [Int32] = []
            for (i, p) in pfds.enumerated() where p.revents != 0 {
                let n = read(p.fd, &buffer, buffer.count)
                if n > 0 {
                    onData(open[i].stream, Data(buffer[0..<n]))
                } else if n == 0 || (errno != EINTR && errno != EAGAIN) {
                    // EOF; or EIO, which is how a pty master reports its last slave closing.
                    closed.append(p.fd)
                }
            }
            for fd in closed { close(fd) }
            open.removeAll { closed.contains($0.fd) }
        }
        for o in open { close(o.fd) }
        done.signal()
    }
}

// MARK: - Spawning

private struct SpawnedProcess {
    /// Also the process group id: every run leads its own group.
    let pid: pid_t
    let fds: [(Int32, RunOutputStream)]
    /// hostd's own descriptor on the pty slave, closed once the run's output is drained.
    let ptySlave: Int32?
}

/// Only fds 0–2 ever reach a run. A run that inherited another run's pipe would hold it open,
/// so that run never saw EOF; one that inherited hostd's socket could talk to the controller.
/// The child side closes everything else (`POSIX_SPAWN_CLOEXEC_DEFAULT` on Darwin,
/// `addclosefrom_np(3)` on glibc ≥ 2.34), and on Linux the parent's own fds are created
/// close-on-exec atomically (`pipe2`, `O_CLOEXEC`), so a `Process` spawned elsewhere in hostd
/// cannot catch one mid-setup either.
private enum Spawner {
    static func spawn(shell: String, command: String, cwd: String, env: [String: String],
                      pty: TerminalSize?) throws -> SpawnedProcess {
        #if canImport(Glibc)
        var actions = posix_spawn_file_actions_t()
        var attr = posix_spawnattr_t()
        #else
        var actions: posix_spawn_file_actions_t?
        var attr: posix_spawnattr_t?
        #endif
        posix_spawn_file_actions_init(&actions)
        posix_spawnattr_init(&attr)
        defer {
            posix_spawn_file_actions_destroy(&actions)
            posix_spawnattr_destroy(&attr)
        }

        var parentFDs: [(Int32, RunOutputStream)] = []
        var childOnly: [Int32] = []
        var ptySlave: Int32?
        func cleanup() {
            for (fd, _) in parentFDs { close(fd) }
            for fd in childOnly { close(fd) }
        }

        if let size = pty {
            let master = try Pty.openMaster()
            parentFDs.append((master.fd, .pty))
            // hostd keeps its own slave descriptor for the run's lifetime. Darwin discards
            // whatever the master has not read yet when the last slave descriptor closes, so
            // without this a run's final lines could vanish as it exits. It is also where the
            // size is set: Darwin resets a size set on the master when the slave first opens.
            let slave = open(master.slavePath, O_RDWR | O_NOCTTY | O_CLOEXEC)
            guard slave >= 0 else {
                let e = errno
                close(master.fd)
                throw RunnerError.spawnFailed(e)
            }
            ptySlave = try Spawner.cloexecAboveStdio(slave)
            var ws = winsize(ws_row: UInt16(clamping: size.rows), ws_col: UInt16(clamping: size.columns),
                             ws_xpixel: 0, ws_ypixel: 0)
            _ = ioctl(ptySlave!, UInt(TIOCSWINSZ), &ws)
            // The child opens the slave itself after setsid, which makes it the controlling
            // terminal: ^C on the pty and `exec </dev/tty` then work as they do locally.
            posix_spawn_file_actions_addopen(&actions, 0, master.slavePath, O_RDWR, 0)
            posix_spawn_file_actions_adddup2(&actions, 0, 1)
            posix_spawn_file_actions_adddup2(&actions, 0, 2)
        } else {
            do {
                let out = try makePipe(), err = try makePipe()
                parentFDs += [(out.read, .stdout), (err.read, .stderr)]
                childOnly += [out.write, err.write]
                posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
                posix_spawn_file_actions_adddup2(&actions, out.write, 1)
                posix_spawn_file_actions_adddup2(&actions, err.write, 2)
            } catch {
                cleanup()
                throw error
            }
        }
        let chdirRC = posix_spawn_file_actions_addchdir_np(&actions, cwd)
        #if canImport(Glibc)
        let closeRC = posix_spawn_file_actions_addclosefrom_np(&actions, 3)
        #else
        let closeRC: Int32 = 0
        #endif
        guard chdirRC == 0, closeRC == 0 else {
            cleanup()
            if let ptySlave { close(ptySlave) }
            throw RunnerError.spawnFailed(chdirRC != 0 ? chdirRC : closeRC)
        }

        // Default dispositions and an empty mask: hostd ignores SIGPIPE (a dead peer must not
        // kill it), and an ignored signal is inherited across exec, so without this every
        // `yes | head` on the host would behave differently from the user's own terminal.
        var all = sigset_t(), none = sigset_t()
        sigfillset(&all)
        sigemptyset(&none)
        posix_spawnattr_setsigdefault(&attr, &all)
        posix_spawnattr_setsigmask(&attr, &none)
        var flags = Int32(POSIX_SPAWN_SETSIGDEF) | Int32(POSIX_SPAWN_SETSIGMASK)
        if pty != nil {
            flags |= spawnSetSID   // a new session is also a new process group
        } else {
            flags |= Int32(POSIX_SPAWN_SETPGROUP)
            posix_spawnattr_setpgroup(&attr, 0)
        }
        #if !canImport(Glibc)
        // Darwin can close every fd not named above, so hostd's sockets never reach a run.
        flags |= Int32(POSIX_SPAWN_CLOEXEC_DEFAULT)
        #endif
        posix_spawnattr_setflags(&attr, Int16(flags))

        let argv = [shell, "-lc", command]
        let envp = env.map { "\($0.key)=\($0.value)" }
        var pid: pid_t = 0
        let rc = withCStrings(argv) { cargv in
            withCStrings(envp) { cenv in
                posix_spawn(&pid, shell, &actions, &attr, cargv, cenv)
            }
        }
        for fd in childOnly { close(fd) }
        guard rc == 0 else {
            for (fd, _) in parentFDs { close(fd) }
            if let ptySlave { close(ptySlave) }
            throw RunnerError.spawnFailed(rc)
        }
        return SpawnedProcess(pid: pid, fds: parentFDs, ptySlave: ptySlave)
    }

    /// Blocks until `pid` exits.
    static func wait(_ pid: pid_t) -> RunExit {
        var status: Int32 = 0
        while waitpid(pid, &status, 0) == -1 {
            if errno != EINTR { return .code(255) }
        }
        // WIFEXITED / WTERMSIG by hand: Swift imports neither macro, and the encoding is the
        // same on Darwin and glibc.
        let low = status & 0x7f
        return low == 0 ? .code((status >> 8) & 0xff) : .signal(low)
    }

    private static func makePipe() throws -> (read: Int32, write: Int32) {
        var fds: [Int32] = [0, 0]
        #if canImport(Glibc)
        guard Libc.pipe2(&fds, O_CLOEXEC) == 0 else { throw RunnerError.spawnFailed(errno) }
        #else
        guard pipe(&fds) == 0 else { throw RunnerError.spawnFailed(errno) }
        #endif
        return (try cloexecAboveStdio(fds[0]), try cloexecAboveStdio(fds[1]))
    }

    /// Marks `fd` close-on-exec, moving it above 2 first. A daemon started with stdin closed
    /// gets fd 0 back from `pipe()`, and the `dup2(…, 0)` file action would then clobber it.
    static func cloexecAboveStdio(_ fd: Int32) throws -> Int32 {
        var fd = fd
        if fd <= 2 {
            let moved = fcntl(fd, F_DUPFD_CLOEXEC, 3)
            close(fd)
            guard moved >= 0 else { throw RunnerError.spawnFailed(errno) }
            fd = moved
        }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        return fd
    }

    private static func withCStrings<R>(_ strings: [String], _ body: ([UnsafeMutablePointer<CChar>?]) -> R) -> R {
        var cstrings = strings.map { strdup($0) }
        cstrings.append(nil)
        defer { for p in cstrings { free(p) } }
        return body(cstrings)
    }

    #if canImport(Glibc)
    /// glibc's value; Swift's Glibc import omits it (it sits behind `_GNU_SOURCE`).
    private static let spawnSetSID: Int32 = 0x80
    #else
    private static let spawnSetSID = Int32(POSIX_SPAWN_SETSID)
    #endif
}

private enum Pty {
    struct Master {
        let fd: Int32
        let slavePath: String
    }

    static func openMaster() throws -> Master {
        #if canImport(Glibc)
        let fd = openpt(O_RDWR | O_NOCTTY | O_CLOEXEC)   // glibc passes flags to open(2)
        #else
        let fd = openpt(O_RDWR | O_NOCTTY)
        #endif
        guard fd >= 0 else { throw RunnerError.spawnFailed(errno) }
        var buf = [CChar](repeating: 0, count: 128)
        guard grant(fd) == 0, unlock(fd) == 0, name(fd, &buf, buf.count) == 0 else {
            let e = errno
            close(fd)
            throw RunnerError.spawnFailed(e)
        }
        let master = try Spawner.cloexecAboveStdio(fd)
        return Master(fd: master, slavePath: buf.withUnsafeBufferPointer { String(cString: $0.baseAddress!) })
    }

    #if canImport(Glibc)
    // Swift's Glibc import hides the XSI pty calls (they need `_XOPEN_SOURCE`), but libc
    // exports them, so they are looked up at runtime instead of hardcoding Linux ioctl numbers.
    private typealias FdCall = @convention(c) (Int32) -> Int32
    private typealias NameCall = @convention(c) (Int32, UnsafeMutablePointer<CChar>?, Int) -> Int32
    private static let openpt = Libc.symbol("posix_openpt", FdCall.self)
    private static let grant = Libc.symbol("grantpt", FdCall.self)
    private static let unlock = Libc.symbol("unlockpt", FdCall.self)
    private static let name = Libc.symbol("ptsname_r", NameCall.self)
    #else
    private static func openpt(_ flags: Int32) -> Int32 { posix_openpt(flags) }
    private static func grant(_ fd: Int32) -> Int32 { grantpt(fd) }
    private static func unlock(_ fd: Int32) -> Int32 { unlockpt(fd) }
    /// The reentrant form: `ptsname` returns a static buffer, and two runs starting a pty at
    /// once on different threads could each read the other's slave path.
    private static func name(_ fd: Int32, _ buf: UnsafeMutablePointer<CChar>, _ len: Int) -> Int32 {
        ptsname_r(fd, buf, len)
    }
    #endif
}

#if canImport(Glibc)
/// libc calls Swift's Glibc import hides (the XSI pty calls need `_XOPEN_SOURCE`, `pipe2`
/// needs `_GNU_SOURCE`). libc exports them, so they are looked up at runtime instead of
/// hardcoding Linux ioctl numbers or syscalls.
private enum Libc {
    static func symbol<T>(_ name: String, _ type: T.Type) -> T {
        // The main program's handle searches every loaded library, libc included.
        unsafeBitCast(dlsym(dlopen(nil, RTLD_NOW), name)!, to: type)
    }
    private typealias Pipe2Call = @convention(c) (UnsafeMutablePointer<Int32>?, Int32) -> Int32
    private static let pipe2Fn = symbol("pipe2", Pipe2Call.self)
    static func pipe2(_ fds: inout [Int32], _ flags: Int32) -> Int32 { pipe2Fn(&fds, flags) }
}
#endif
