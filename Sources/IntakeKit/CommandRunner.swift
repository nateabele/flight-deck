import Foundation
import Darwin

/// What one command run produced: raw stdout (a harness's JSONL is parsed byte-wise), stderr
/// as text (enough for an error message), and the exit code a shell script would report.
public struct CommandResult: Sendable {
    public let stdout: Data
    public let stderr: String
    public let exitCode: Int32
    public init(stdout: Data, stderr: String, exitCode: Int32) {
        self.stdout = stdout; self.stderr = stderr; self.exitCode = exitCode
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
}

extension CommandRunner {
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
    public init() {}

    public func run(executable: String, arguments: [String], cwd: URL, environment: [String: String],
                     processGroup: Bool, onSpawn: (@Sendable (Int32) -> Void)?) async throws -> CommandResult {
        if processGroup {
            return try await runInNewProcessGroup(executable: executable, arguments: arguments, cwd: cwd,
                                                  environment: environment, onSpawn: onSpawn)
        }
        return try await runViaFoundationProcess(executable: executable, arguments: arguments, cwd: cwd,
                                                  environment: environment, onSpawn: onSpawn)
    }

    // MARK: - Foundation.Process path (moved from the app's SystemHeadlessRunner, unchanged)

    private func runViaFoundationProcess(
        executable: String, arguments: [String], cwd: URL, environment: [String: String],
        onSpawn: (@Sendable (Int32) -> Void)?
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
                    out.data = stdoutPipe.fileHandleForReading.readDataToEndOfFile(); group.leave()
                }
                group.enter()
                DispatchQueue.global().async {
                    err.data = stderrPipe.fileHandleForReading.readDataToEndOfFile(); group.leave()
                }
                group.notify(queue: .global()) {
                    process.waitUntilExit()
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

    private struct RawPipe { let readFD: Int32; let writeFD: Int32 }

    private static func makePipe() throws -> RawPipe {
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { throw SpawnFailed(step: "pipe", errno: errno) }
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
        onSpawn: (@Sendable (Int32) -> Void)?
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
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attr, 0)

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
        let result: (Data, Data, Int32, Bool) = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let group = DispatchGroup()
                let out = Buffer(), err = Buffer()
                group.enter()
                DispatchQueue.global().async {
                    out.data = FileHandle(fileDescriptor: outPipe.readFD, closeOnDealloc: true).readDataToEndOfFile()
                    group.leave()
                }
                group.enter()
                DispatchQueue.global().async {
                    err.data = FileHandle(fileDescriptor: errPipe.readFD, closeOnDealloc: true).readDataToEndOfFile()
                    group.leave()
                }
                group.notify(queue: .global()) {
                    var status: Int32 = 0
                    var rc: pid_t = -1
                    // A signal delivered to THIS process (not the child) while blocked in
                    // `waitpid` interrupts the call with EINTR and leaves `status` untouched —
                    // at zero, which decodes below as a clean exit 0. Retrying is the only way
                    // to avoid reporting a killed/failing child as a success.
                    repeat {
                        rc = waitpid(childPID, &status, 0)
                    } while rc == -1 && errno == EINTR
                    guard rc != -1 else {
                        continuation.resume(throwing: WaitFailed(errno: errno))
                        return
                    }
                    exitFlag.markExited()
                    // `WIFSIGNALED`/`WTERMSIG`/`WEXITSTATUS` are `#define`s, not C functions —
                    // Swift can't call them, so this is their BSD wait-status layout by hand.
                    let low7 = status & 0x7f
                    let signaled = low7 != 0 && low7 != 0x7f
                    let code = signaled ? low7 : (status >> 8) & 0xff
                    continuation.resume(returning: (out.data, err.data, code, signaled))
                }
            }
        } onCancel: {
            // SIGTERM the whole group first — the common case (the ladder in
            // `SessionReaper` is the same idea): most things exit cleanly on it. Guarded by
            // `exitFlag` the same as the delayed SIGKILL below, because `waitpid` above can
            // already have reaped (and the kernel can already have recycled) `childPID` by the
            // time this cancellation handler runs.
            if !exitFlag.hasExited { killpg(childPID, SIGTERM) }
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                if !exitFlag.hasExited { killpg(childPID, SIGKILL) }
            }
        }

        if Task.isCancelled { throw CancellationError() }
        var stderr = String(decoding: result.1, as: UTF8.self)
        guard result.3 else { return CommandResult(stdout: result.0, stderr: stderr, exitCode: result.2) }
        stderr = "terminated by signal \(result.2)" + (stderr.isEmpty ? "" : "\n" + stderr)
        return CommandResult(stdout: result.0, stderr: stderr, exitCode: 128 + result.2)
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
