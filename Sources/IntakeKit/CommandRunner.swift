import Foundation
import Darwin

/// What one command run produced: raw stdout (a harness's JSONL is parsed byte-wise), stderr
/// as text (enough for an error message), and the exit code a shell script would report.
public struct CommandResult: Sendable {
    public let stdout: Data
    public let stderr: String
    public let exitCode: Int32
    /// True when the runner dropped stdout past the caller's `stdoutCapture`.
    public let stdoutTruncated: Bool
    public init(stdout: Data, stderr: String, exitCode: Int32, stdoutTruncated: Bool = false) {
        self.stdout = stdout; self.stderr = stderr; self.exitCode = exitCode; self.stdoutTruncated = stdoutTruncated
    }
}

/// Runs one external process to completion. A protocol so a caller (`GraphReader`, the app's
/// `IntakeService`) can hand back canned output in tests instead of spawning a real one.
public protocol CommandRunner: Sendable {
    /// `environment` is the COMPLETE child environment (the caller resolves PATH — see
    /// `LoginShellPath`). `processGroup: true` starts the child as the leader of a brand-new
    /// process group, so a caller holding just its pid can later `killpg` the whole subtree it
    /// forked (Task 7's ⏹ needs to reach a `sh -c 'a & b'`'s grandchildren, not just the
    /// shell). `onSpawn`, when non-nil, is called with the child's pid immediately after it
    /// starts — the only way to observe it, since this method doesn't return until the process
    /// exits.
    func run(executable: String, arguments: [String], cwd: URL, environment: [String: String],
             processGroup: Bool, onSpawn: (@Sendable (Int32) -> Void)?) async throws -> CommandResult

    /// The same, with `onStdout` called with each chunk of stdout as the child writes it —
    /// serially, from one reader thread, in order — so a caller can keep a live copy of a
    /// long run's stream on disk. The returned `CommandResult.stdout` is still the whole of it.
    func run(executable: String, arguments: [String], cwd: URL, environment: [String: String],
             processGroup: Bool, onSpawn: (@Sendable (Int32) -> Void)?,
             onStdout: (@Sendable (Data) -> Void)?) async throws -> CommandResult

    /// The same, keeping at most `stdoutCapture` bytes of stdout in the result. The sink still
    /// sees every byte; the rest is drained and dropped, so a flood costs no memory.
    func run(executable: String, arguments: [String], cwd: URL, environment: [String: String],
             processGroup: Bool, onSpawn: (@Sendable (Int32) -> Void)?,
             onStdout: (@Sendable (Data) -> Void)?, stdoutCapture: Int?) async throws -> CommandResult
}

extension CommandRunner {
    /// A runner that can't stream (every test fake) hands the sink the whole stdout once, at
    /// exit: a caller that builds its stream file through the sink then still gets the file.
    public func run(executable: String, arguments: [String], cwd: URL, environment: [String: String],
                    processGroup: Bool, onSpawn: (@Sendable (Int32) -> Void)?,
                    onStdout: (@Sendable (Data) -> Void)?) async throws -> CommandResult {
        let result = try await run(executable: executable, arguments: arguments, cwd: cwd, environment: environment,
                                   processGroup: processGroup, onSpawn: onSpawn)
        if let onStdout, !result.stdout.isEmpty { onStdout(result.stdout) }
        return result
    }

    /// A fake has nothing to bound, so it truncates after the fact.
    public func run(executable: String, arguments: [String], cwd: URL, environment: [String: String],
                    processGroup: Bool, onSpawn: (@Sendable (Int32) -> Void)?,
                    onStdout: (@Sendable (Data) -> Void)?, stdoutCapture: Int?) async throws -> CommandResult {
        let result = try await run(executable: executable, arguments: arguments, cwd: cwd, environment: environment,
                                   processGroup: processGroup, onSpawn: onSpawn, onStdout: onStdout)
        guard let stdoutCapture, result.stdout.count > stdoutCapture else { return result }
        return CommandResult(stdout: result.stdout.prefix(stdoutCapture), stderr: result.stderr, exitCode: result.exitCode,
                             stdoutTruncated: true)
    }

    /// The common case: no process group, nobody needs the pid while it runs.
    public func run(executable: String, arguments: [String], cwd: URL,
                     environment: [String: String]) async throws -> CommandResult {
        try await run(executable: executable, arguments: arguments, cwd: cwd, environment: environment,
                       processGroup: false, onSpawn: nil)
    }
}

/// Spawns real processes. Two code paths, chosen by `processGroup`:
/// - `false` (the common case, everything Task 1 through Task 6 need): `Foundation.Process`,
///   through `/usr/bin/env` so a bare executable name resolves the same way it would in a
///   shell — moved unchanged from the app's old `SystemHeadlessRunner`.
/// - `true`: `Process` has no API to put a child in a new process group, so this drops to
///   `posix_spawn` directly with `POSIX_SPAWN_SETPGROUP`, wiring stdin/stdout/stderr by hand
///   through `posix_spawn_file_actions_t`.
public struct SystemCommandRunner: CommandRunner {
    /// How much stderr the process-group path keeps. stderr is "enough for an error message";
    /// a child that floods it is still drained to EOF so it never blocks, but the rest is dropped.
    public static let stderrCapture = 1 << 20
    public static let stderrTruncatedNote = "\n[stderr truncated]"

    /// What the post-grace holder sweep asks the kernel; `.system` outside tests.
    let probe: PipeProbe
    /// How long a drain may wait on a holder nothing can see once the PIPE_EOF bit failed its
    /// self-test (the scan then is all there is, and it can miss another user's process).
    let untrustedDrainLimit: TimeInterval

    public init() { self.init(probe: .system, untrustedDrainLimit: SystemCommandRunner.defaultUntrustedDrainLimit) }

    init(probe: PipeProbe, untrustedDrainLimit: TimeInterval) {
        self.probe = probe
        self.untrustedDrainLimit = untrustedDrainLimit
    }

    /// Ten minutes, a provider generator's longest timeout, plus the drain grace.
    static let defaultUntrustedDrainLimit: TimeInterval = 600 + drainGrace

    static let abandonedNote = "\n[stopped waiting for output still held by a process that could not be stopped]"

    public func run(executable: String, arguments: [String], cwd: URL, environment: [String: String],
                     processGroup: Bool, onSpawn: (@Sendable (Int32) -> Void)?) async throws -> CommandResult {
        try await run(executable: executable, arguments: arguments, cwd: cwd, environment: environment,
                      processGroup: processGroup, onSpawn: onSpawn, onStdout: nil)
    }

    public func run(executable: String, arguments: [String], cwd: URL, environment: [String: String],
                    processGroup: Bool, onSpawn: (@Sendable (Int32) -> Void)?,
                    onStdout: (@Sendable (Data) -> Void)?) async throws -> CommandResult {
        try await run(executable: executable, arguments: arguments, cwd: cwd, environment: environment,
                      processGroup: processGroup, onSpawn: onSpawn, onStdout: onStdout, stdoutCapture: nil)
    }

    public func run(executable: String, arguments: [String], cwd: URL, environment: [String: String],
                    processGroup: Bool, onSpawn: (@Sendable (Int32) -> Void)?,
                    onStdout: (@Sendable (Data) -> Void)?, stdoutCapture: Int?) async throws -> CommandResult {
        if processGroup {
            return try await runInNewProcessGroup(executable: executable, arguments: arguments, cwd: cwd,
                                                  environment: environment, onSpawn: onSpawn, onStdout: onStdout,
                                                  stdoutCapture: stdoutCapture)
        }
        // The Process path reads with Foundation and is not bounded while it runs; nothing that
        // needs a bound (a sandboxed generator) uses it, so it only truncates the result.
        let result = try await runViaFoundationProcess(executable: executable, arguments: arguments, cwd: cwd,
                                                       environment: environment, onSpawn: onSpawn, onStdout: onStdout)
        guard let stdoutCapture, result.stdout.count > stdoutCapture else { return result }
        return CommandResult(stdout: result.stdout.prefix(stdoutCapture), stderr: result.stderr, exitCode: result.exitCode,
                             stdoutTruncated: true)
    }

    /// Reads `handle` to EOF on the calling thread, handing each chunk to `sink` as it lands.
    /// `readDataToEndOfFile` returns only at EOF — i.e. at exit — which is exactly what a live
    /// stream file can't wait for. Raw `read(2)`, not `FileHandle.read(upToCount:)`: on a
    /// `Pipe`'s handle that blocks until the full count or EOF (observed: the Process path's
    /// sink got "ab" at exit while the posix_spawn path's got "a" at once).
    private static func drain(_ handle: FileHandle, _ sink: (@Sendable (Data) -> Void)?) -> Data {
        guard let sink else { return handle.readDataToEndOfFile() }
        var all = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let n = buffer.withUnsafeMutableBytes { read(handle.fileDescriptor, $0.baseAddress, $0.count) }
            if n < 0, errno == EINTR { continue }
            guard n > 0 else { break }
            let chunk = Data(buffer[0..<n])
            all.append(chunk)
            sink(chunk)
        }
        return all
    }

    /// How long the drains may run on after the leader is reaped before the pipe's remaining
    /// holders are killed.
    static let drainGrace: TimeInterval = 1

    /// Reads `fd` until EOF or until `abandon` is set. `poll` with a short timeout, so an
    /// abandoned drain returns even while some process still holds the write end open. With
    /// `keep`, only the first `keep` bytes are kept; the rest is still read, so the writer
    /// never blocks on a full pipe, and `dropped` says so.
    private static func pollingDrain(_ fd: Int32, keep: Int?, sink: (@Sendable (Data) -> Void)?,
                                     abandon: Latch) -> (data: Data, dropped: Bool) {
        var all = Data()
        var dropped = false
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while !abandon.isSet {
            var request = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&request, 1, 50)
            if ready < 0 { if errno == EINTR { continue }; break }
            if ready == 0 { continue }
            let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if n < 0 { if errno == EINTR || errno == EAGAIN { continue }; break }
            guard n > 0 else { break }
            let chunk = Data(buffer[0..<n])
            if let keep {
                let room = keep - all.count
                if room >= n { all.append(chunk) } else {
                    if room > 0 { all.append(chunk.prefix(room)) }
                    dropped = true
                }
            } else {
                all.append(chunk)
            }
            sink?(chunk)
        }
        return (all, dropped)
    }

    /// XNU's `PIPE_EOF` in `pipe_status`: set on a read end once its last write end has closed,
    /// whoever held it, even with bytes still buffered (measured). It answers "can a writer
    /// still exist" for processes the libproc scan cannot inspect, too, but only while it
    /// behaves: `PipeProbe` self-tests it and believes the scan over it.
    private static let pipeEOF: Int32 = 0x80

    /// The `PIPE_EOF` bit of one of our read ends, or nil when it cannot be read.
    static func eofBit(_ fd: Int32) -> Bool? {
        let infoSize = Int32(MemoryLayout<pipe_fdinfo>.size)
        var info = pipe_fdinfo()
        guard proc_pidfdinfo(getpid(), fd, PROC_PIDFDPIPEINFO, &info, infoSize) == infoSize else { return nil }
        return info.pipeinfo.pipe_status & pipeEOF != 0
    }

    /// What `killPipeWriters` asks the kernel and does to holders. A seam, so tests can make
    /// the `PIPE_EOF` bit wrong in either direction; `.system` is the real one.
    struct PipeProbe: Sendable {
        var eofBit: @Sendable (Int32) -> Bool?
        var writers: @Sendable ([Int32]) -> Set<pid_t>
        var signal: @Sendable (pid_t, Int32) -> Void

        /// Whether `eofBit` passed `selfTest`. When it did not, only the scan is believed.
        let bitTrusted: Bool

        init(eofBit: @escaping @Sendable (Int32) -> Bool?, writers: @escaping @Sendable ([Int32]) -> Set<pid_t>,
             signal: @escaping @Sendable (pid_t, Int32) -> Void) {
            self.eofBit = eofBit; self.writers = writers; self.signal = signal
            bitTrusted = Self.selfTest(eofBit)
        }

        /// A `static let`, so the real bit is self-tested once per process.
        static let system = PipeProbe(eofBit: SystemCommandRunner.eofBit, writers: SystemCommandRunner.pipeWriters(of:),
                                      signal: { _ = kill($0, $1) })

        /// One fresh pipe: the bit must be clear while its write end is open and set once that
        /// closes. A kernel whose bit is never set would have every drain abandoned (a slow
        /// sink silently cut); one whose bit is set early would have a drain awaited forever.
        static func selfTest(_ bit: (Int32) -> Bool?) -> Bool {
            var fds: [Int32] = [0, 0]
            guard pipe(&fds) == 0 else { return false }
            let whileOpen = bit(fds[0])
            close(fds[1])
            let afterClose = bit(fds[0])
            close(fds[0])
            return whileOpen == false && afterClose == true
        }

        /// True when a write end of one of `readFDs` may still be open. A holder the scan finds
        /// is alive whatever the bit says. With none found, a trusted bit still speaks for a
        /// holder the scan cannot inspect; an untrusted one is ignored.
        func writerMayRemain(_ readFDs: [Int32]) -> Bool {
            // A trusted bit that says "open" needs no scan (about 10 ms each, measured).
            if bitTrusted, !readFDs.allSatisfy({ eofBit($0) == true }) { return true }
            return !writers(readFDs).isEmpty
        }
    }

    /// Every other process holding a write end of one of our pipes. A holder that left the
    /// process group is out of reach of every group signal; libproc is the only place that
    /// knows it has our pipe. A writer's `pipe_handle` is our read end's `pipe_peerhandle`.
    static func pipeWriters(of readFDs: [Int32]) -> Set<pid_t> {
        let infoSize = Int32(MemoryLayout<pipe_fdinfo>.size)
        var peers = Set<UInt64>()
        for fd in readFDs {
            var info = pipe_fdinfo()
            if proc_pidfdinfo(getpid(), fd, PROC_PIDFDPIPEINFO, &info, infoSize) == infoSize {
                peers.insert(info.pipeinfo.pipe_peerhandle)
            }
        }
        guard !peers.isEmpty else { return [] }
        let me = getpid()
        let capacity = proc_listallpids(nil, 0)
        guard capacity > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(capacity) + 64)
        let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        let fdStride = MemoryLayout<proc_fdinfo>.stride
        var writers = Set<pid_t>()
        for pid in pids.prefix(max(0, Int(count))) where pid > 0 && pid != me {
            let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
            guard bytes > 0 else { continue }
            var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bytes) / fdStride + 8)
            let used = fds.withUnsafeMutableBytes { proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count)) }
            guard used > 0 else { continue }
            for entry in fds.prefix(Int(used) / fdStride) where entry.proc_fdtype == UInt32(PROX_FDTYPE_PIPE) {
                var info = pipe_fdinfo()
                if proc_pidfdinfo(pid, entry.proc_fd, PROC_PIDFDPIPEINFO, &info, infoSize) == infoSize,
                   peers.contains(info.pipeinfo.pipe_handle) {
                    writers.insert(pid)
                    break
                }
            }
        }
        return writers
    }

    /// SIGTERM to every holder of our pipes, half a second for them to close (an MCP server or
    /// an ssh master shuts down cleanly on it), then SIGKILL to whatever still holds one, found
    /// by a fresh scan so a holder forked meanwhile is caught too. `stopped` counts the processes
    /// signalled; `writerAlive` is true only if a write end may still be open afterwards (a
    /// holder that survived, or one this user may not inspect), the one case in which EOF
    /// cannot be awaited.
    static func killPipeWriters(of readFDs: [Int32], probe: PipeProbe = .system) -> (stopped: Int, writerAlive: Bool) {
        func waitForEOF(_ seconds: Double) {
            let deadline = Date().addingTimeInterval(seconds)
            while probe.writerMayRemain(readFDs), Date() < deadline { usleep(10_000) }
        }
        var signalled = probe.writers(readFDs)
        for pid in signalled { probe.signal(pid, SIGTERM) }
        if !signalled.isEmpty { waitForEOF(0.5) }
        if probe.writerMayRemain(readFDs) {
            let stubborn = probe.writers(readFDs)
            for pid in stubborn { probe.signal(pid, SIGKILL) }
            signalled.formUnion(stubborn)
            if !stubborn.isEmpty { waitForEOF(1) }
        }
        return (signalled.count, probe.writerMayRemain(readFDs))
    }

    /// "Stopped": a holder that exits cleanly on SIGTERM was asked, not killed.
    static func killedHoldersNote(_ count: Int) -> String {
        "\n[stopped \(count) background processes still holding output]"
    }

    // MARK: - Foundation.Process path (moved from the app's SystemHeadlessRunner)

    private func runViaFoundationProcess(
        executable: String, arguments: [String], cwd: URL, environment: [String: String],
        onSpawn: (@Sendable (Int32) -> Void)?, onStdout: (@Sendable (Data) -> Void)?
    ) async throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [executable] + arguments
        process.currentDirectoryURL = cwd
        process.environment = environment
        // Both CLIs look at stdin when it is not a TTY (as extra prompt input); an inherited
        // stdin that never reaches EOF would stall a run that should need no input at all.
        process.standardInput = FileHandle.nullDevice

        let stdoutPipe = Pipe(), stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // Exit is observed through `terminationHandler`, never `waitUntilExit()`. The latter
        // spins the calling thread's run loop waiting for Foundation's exit notification, and
        // called from a GCD worker (below) it can miss it and block forever after the child is
        // long gone — sampled on 2026-09-27 with four concurrent test runs, every one wedged in
        // `waitUntilExit` with no child left. The handler is set before `run()` so an instant
        // exit can't slip past it.
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }

        try Task.checkCancellation()
        try process.run()
        onSpawn?(process.processIdentifier)

        // Both pipes drain on their own threads, off the cooperative pool: a triage run goes
        // for minutes, and either stream filling its 64KB buffer while we block on the other
        // is the classic Foundation.Process deadlock (see `LoginShellPath.defaultRun`).
        let result: (Data, Data, Int32, Bool) = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let group = DispatchGroup()
                let out = Buffer(), err = Buffer()
                group.enter()
                DispatchQueue.global().async {
                    out.data = Self.drain(stdoutPipe.fileHandleForReading, onStdout); group.leave()
                }
                group.enter()
                DispatchQueue.global().async {
                    err.data = stderrPipe.fileHandleForReading.readDataToEndOfFile(); group.leave()
                }
                group.notify(queue: .global()) {
                    exited.wait()
                    continuation.resume(returning: (out.data, err.data, process.terminationStatus,
                                                    process.terminationReason == .uncaughtSignal))
                }
            }
        } onCancel: {
            // SIGTERM: the child exits, the kernel closes its ends of both pipes, the reads
            // above hit EOF and the continuation resumes — a discarded or retried run stops
            // its process instead of letting it run to completion unobserved.
            process.terminate()
        }

        // Only OUR cancellation is a CancellationError. A child killed by some other signal
        // (OOM, a user's `kill`) is a failed run the human must see, so it comes back as a
        // nonzero shell-style code (128 + signal) with the signal named in stderr.
        if Task.isCancelled { throw CancellationError() }
        var stderr = String(decoding: result.1, as: UTF8.self)
        guard result.3 else { return CommandResult(stdout: result.0, stderr: stderr, exitCode: result.2) }
        stderr = "terminated by signal \(result.2)" + (stderr.isEmpty ? "" : "\n" + stderr)
        return CommandResult(stdout: result.0, stderr: stderr, exitCode: 128 + result.2)
    }

    private final class Buffer: @unchecked Sendable { var data = Data() }

    // MARK: - posix_spawn path (own process group, for Task 7's whole-subtree kill)

    /// A one-way flag shared between the reaper and the drain threads.
    private final class Latch: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.lock(); value = true; lock.unlock() }
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    }

    struct RawPipe { let readFD: Int32; let writeFD: Int32 }

    static func makePipe() throws -> RawPipe {
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { throw SpawnFailed(step: "pipe", errno: errno) }
        // Close-on-exec at once, on all four ends. CLOEXEC_DEFAULT covers only this runner's
        // own spawn; anything else the app forks meanwhile (libghostty's shell for a new tab)
        // would inherit a write end, and the holder sweep after the round would then kill it.
        // The child still gets 1 and 2: `adddup2` clears the flag on the copies it makes.
        for fd in fds where fcntl(fd, F_SETFD, FD_CLOEXEC) != 0 {
            let error = errno
            close(fds[0]); close(fds[1])
            throw SpawnFailed(step: "fcntl", errno: error)
        }
        return RawPipe(readFD: fds[0], writeFD: fds[1])
    }

    /// Set once `waitpid` has reaped the child — checked by the cancellation handler's
    /// delayed `SIGKILL` so it never signals a pid the kernel may already have recycled for
    /// an unrelated process.
    private final class ExitFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var exited = false
        func markExited() { lock.lock(); exited = true; lock.unlock() }
        var hasExited: Bool { lock.lock(); defer { lock.unlock() }; return exited }
    }

    private func runInNewProcessGroup(
        executable: String, arguments: [String], cwd: URL, environment: [String: String],
        onSpawn: (@Sendable (Int32) -> Void)?, onStdout: (@Sendable (Data) -> Void)?, stdoutCapture: Int?
    ) async throws -> CommandResult {
        try Task.checkCancellation()

        let outPipe = try Self.makePipe()
        let errPipe = try Self.makePipe()

        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        // `_np`, not the macOS 26+-only replacement: the deployment target here is 14.0.
        posix_spawn_file_actions_addchdir_np(&fileActions, cwd.path)
        posix_spawn_file_actions_addopen(&fileActions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&fileActions, outPipe.writeFD, 1)
        posix_spawn_file_actions_adddup2(&fileActions, errPipe.writeFD, 2)
        posix_spawn_file_actions_addclose(&fileActions, outPipe.readFD)
        posix_spawn_file_actions_addclose(&fileActions, outPipe.writeFD)
        posix_spawn_file_actions_addclose(&fileActions, errPipe.readFD)
        posix_spawn_file_actions_addclose(&fileActions, errPipe.writeFD)

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        // A new process group, led by the child itself (pgid 0 => "make it my own pid") — so
        // a caller holding just the pid can `killpg` everything the child forks, the way
        // `SessionReaper`/`ForkedChild` already do for the app's own agent processes.
        // SETSIGMASK (empty) + SETSIGDEF: libdispatch workqueue threads — every thread Swift
        // concurrency runs this on — start with the async signals blocked, and `posix_spawn`
        // hands the child the SPAWNING THREAD's mask (plus any ignored dispositions); `Process`
        // resets both, raw spawn does not. So in the app as much as under xctest, a child
        // spawned here had SIGTERM blocked: `killpg(pid, SIGTERM)` returned 0 yet `sleep 30`
        // ran to completion, ⏹ only ever landed via the SIGKILL a second later, and no harness
        // got a chance to shut down cleanly.
        // CLOEXEC_DEFAULT: the child gets 0/1/2 from the file actions above and nothing else.
        // Without it every descriptor the app opened without O_CLOEXEC rode along, and a
        // sandboxed child used one to write outside its sandbox: the sandbox checks paths at
        // open, never a descriptor it was handed already open. (HostKit's Runner does the same.)
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK
                                              | POSIX_SPAWN_CLOEXEC_DEFAULT))
        posix_spawnattr_setpgroup(&attr, 0)
        var allSignals = sigset_t(), noSignals = sigset_t()
        sigfillset(&allSignals); sigemptyset(&noSignals)
        posix_spawnattr_setsigdefault(&attr, &allSignals)
        posix_spawnattr_setsigmask(&attr, &noSignals)

        // argv[0] is "/usr/bin/env" itself — `Process` inserts this automatically (its
        // `arguments` docs say so explicitly), but raw `posix_spawn` does not: without it,
        // `env`'s own argv[0]-skipping parser reads `executable` as ITS program name and
        // `arguments[0]` (e.g. `-c`) as an unrecognized option, so the real command never runs.
        let argv = (["/usr/bin/env", executable] + arguments).map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { argv.forEach { free($0) }; envp.forEach { free($0) } }

        var pid: pid_t = 0
        let spawnRC = "/usr/bin/env".withCString { envToolPath in
            posix_spawn(&pid, envToolPath, &fileActions, &attr, argv, envp)
        }
        // The child dup'd the write ends onto 1/2 and closed its own copies via `fileActions`
        // above, but OUR copies are still open — without closing them here, the reads below
        // would block forever waiting for an EOF that a write end we're still holding open
        // can never deliver, even after the child exits.
        close(outPipe.writeFD)
        close(errPipe.writeFD)
        guard spawnRC == 0 else {
            close(outPipe.readFD); close(errPipe.readFD)
            throw SpawnFailed(step: "posix_spawn", errno: spawnRC)
        }
        // A `let` copy: `pid` only needs to be `var` for `posix_spawn` to write into, but the
        // cancellation closure below runs concurrently, and Swift 6 won't let it capture a
        // `var` — nor should it, since nothing here mutates `pid` again after this point.
        let childPID = pid
        onSpawn?(childPID)

        let exitFlag = ExitFlag()
        let abandon = Latch()
        let result: (Data, Data, Int32, Bool, Bool) = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let drains = DispatchGroup()
                let out = Buffer(), err = Buffer(), errDropped = Latch(), outDropped = Latch()
                drains.enter()
                DispatchQueue.global().async {
                    let drained = Self.pollingDrain(outPipe.readFD, keep: stdoutCapture, sink: onStdout, abandon: abandon)
                    out.data = drained.data
                    if drained.dropped { outDropped.set() }
                    drains.leave()
                }
                drains.enter()
                DispatchQueue.global().async {
                    let drained = Self.pollingDrain(errPipe.readFD, keep: Self.stderrCapture, sink: nil, abandon: abandon)
                    err.data = drained.data
                    if drained.dropped { errDropped.set() }
                    drains.leave()
                }
                // The reaper runs BESIDE the drains, not after them. Waiting for EOF first meant
                // a process that left the group (a double fork into `setsid`) and kept stdout
                // open held the run forever: no group signal reaches it, and nothing reaped the
                // leader until it closed the pipe.
                DispatchQueue.global().async {
                    var status: Int32 = 0
                    var rc: pid_t = -1
                    // A signal delivered to THIS process (not the child) while blocked in
                    // `waitpid` interrupts the call with EINTR and leaves `status` untouched —
                    // at zero, which decodes below as a clean exit 0. Retrying is the only way
                    // to avoid reporting a killed/failing child as a success.
                    repeat {
                        rc = waitpid(childPID, &status, 0)
                    } while rc == -1 && errno == EINTR
                    let waitErrno = errno
                    if rc != -1 { exitFlag.markExited() }
                    // The leader is gone. Output still in flight gets a grace; after it, whoever
                    // still holds a write end is an orphan of this run and is killed, so the
                    // drains see EOF. Our read ends stay open until then: the scan matches the
                    // holders' handles against them.
                    var stopped = 0
                    if drains.wait(timeout: .now() + Self.drainGrace) == .timedOut {
                        let outcome = Self.killPipeWriters(of: [outPipe.readFD, errPipe.readFD], probe: probe)
                        stopped = outcome.stopped
                        // With no writer left EOF is certain, so the drains finish on their own
                        // however slow the sink is: cutting them off here lost the tail of a
                        // slow sink's stream (a round's final JSON line). Only a writer still
                        // alive, one we could not see or kill, can hold them forever.
                        if outcome.writerAlive {
                            abandon.set()
                        } else if !probe.bitTrusted,
                                  drains.wait(timeout: .now() + untrustedDrainLimit) == .timedOut {
                            // An untrusted bit cannot speak for a holder the scan cannot see,
                            // so "no writer found" is not proof of EOF: bounded, then abandoned.
                            abandon.set()
                        }
                        drains.wait()
                    }
                    close(outPipe.readFD)
                    close(errPipe.readFD)
                    guard rc != -1 else {
                        continuation.resume(throwing: WaitFailed(errno: waitErrno))
                        return
                    }
                    if errDropped.isSet { err.data.append(Data(Self.stderrTruncatedNote.utf8)) }
                    // A holder killed above may have been a same-group child with late output
                    // still to write; its loss is never silent.
                    if stopped > 0 { err.data.append(Data(Self.killedHoldersNote(stopped).utf8)) }
                    if abandon.isSet { err.data.append(Data(Self.abandonedNote.utf8)) }
                    // `WIFSIGNALED`/`WTERMSIG`/`WEXITSTATUS` are `#define`s, not C functions —
                    // Swift can't call them, so this is their BSD wait-status layout by hand.
                    let low7 = status & 0x7f
                    let signaled = low7 != 0 && low7 != 0x7f
                    let code = signaled ? low7 : (status >> 8) & 0xff
                    continuation.resume(returning: (out.data, err.data, code, signaled, outDropped.isSet))
                }
            }
        } onCancel: {
            // SIGTERM the whole group first — the common case (the ladder in
            // `SessionReaper` is the same idea): most things exit cleanly on it. Guarded by
            // `exitFlag`, because `waitpid` above can already have reaped (and the kernel can
            // already have recycled) `childPID` by the time this cancellation handler runs; the
            // delayed SIGKILL below re-checks the group itself instead.
            if !exitFlag.hasExited { killpg(childPID, SIGTERM) }
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                // Sweep the GROUP, not just the leader: a descendant that ignores SIGTERM and
                // detached its streams outlives a leader that exited cleanly on it, and would
                // otherwise run on unowned. Safe after the leader is reaped because a pid is
                // never reused while a process group with that id still has a member — so if
                // `killpg(_, 0)` finds the group, it is still ours. (Only once the group is
                // empty could the id be recycled, and then the probe finds nothing to kill.)
                if !exitFlag.hasExited || killpg(childPID, 0) == 0 { killpg(childPID, SIGKILL) }
                // The caller's clock has run out (a sandbox's timeout): with an untrusted bit a
                // drain may be waiting on a holder nothing can see, so the cancel ends it too.
                if !probe.bitTrusted { abandon.set() }
            }
        }

        if Task.isCancelled { throw CancellationError() }
        var stderr = String(decoding: result.1, as: UTF8.self)
        guard result.3 else {
            return CommandResult(stdout: result.0, stderr: stderr, exitCode: result.2, stdoutTruncated: result.4)
        }
        stderr = "terminated by signal \(result.2)" + (stderr.isEmpty ? "" : "\n" + stderr)
        return CommandResult(stdout: result.0, stderr: stderr, exitCode: 128 + result.2, stdoutTruncated: result.4)
    }
}

/// A `posix_spawn`-path failure that has nothing to do with the child's own exit — the pipe
/// or the spawn call itself failed, before there was a child to report on.
struct SpawnFailed: Error, Equatable {
    let step: String
    let errno: Int32
}

/// `waitpid` failed for a reason other than EINTR (already retried) — e.g. the child was
/// reaped by something else first (ECHILD). There is no exit status to decode, so this can't
/// be folded into a `CommandResult` the way a normal exit or signal death can.
struct WaitFailed: Error, Equatable {
    let errno: Int32
}
