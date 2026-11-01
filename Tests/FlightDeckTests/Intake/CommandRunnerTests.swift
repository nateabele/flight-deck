import XCTest
@testable import IntakeKit

/// `SystemCommandRunner`'s `Foundation.Process` path — moved unchanged from the app's old
/// `SystemHeadlessRunner`, which `HeadlessRunnerTests`-equivalent coverage (now
/// `SystemHeadlessRunnerTests` in `IntakeServiceTests.swift`) still exercises through the
/// app's thin adapter. These prove the IntakeKit type itself, real processes, cheap.
final class CommandRunnerTests: XCTestCase {
    let env = ["PATH": "/usr/bin:/bin"]

    func testCapturesStdoutStderrAndExitCode() async throws {
        let r = try await SystemCommandRunner().run(
            executable: "sh", arguments: ["-c", "printf out; printf err >&2; exit 3"],
            cwd: URL(fileURLWithPath: "/tmp"), environment: env)
        XCTAssertEqual(String(decoding: r.stdout, as: UTF8.self), "out")
        XCTAssertEqual(r.stderr, "err")
        XCTAssertEqual(r.exitCode, 3)
    }

    func testEnvironmentIsExactlyWhatWasPassed() async throws {
        let r = try await SystemCommandRunner().run(
            executable: "sh", arguments: ["-c", "printf \"$FOO|$CLAUDECODE\""],
            cwd: URL(fileURLWithPath: "/tmp"), environment: env.merging(["FOO": "x"]) { $1 })
        XCTAssertEqual(String(decoding: r.stdout, as: UTF8.self), "x|")
    }

    func testCancellationThrows() async {
        let t = Task {
            try await SystemCommandRunner().run(executable: "sleep", arguments: ["30"],
                                                cwd: URL(fileURLWithPath: "/tmp"), environment: env)
        }
        try? await Task.sleep(nanoseconds: 200_000_000)
        t.cancel()
        do {
            _ = try await t.value
            XCTFail("expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testLargeOutputDoesNotDeadlock() async throws {
        let r = try await SystemCommandRunner().run(
            executable: "sh", arguments: ["-c", "head -c 2000000 /dev/zero | tr '\\0' a"],
            cwd: URL(fileURLWithPath: "/tmp"), environment: env)
        XCTAssertEqual(r.stdout.count, 2_000_000)
    }

    /// The non-cancelled `posix_spawn` path (`processGroup: true`) has its own argv/envp
    /// construction and its own fd wiring (`posix_spawn_file_actions_t` rather than `Process`),
    /// so a normal exit needs its own coverage rather than relying on the cancellation test
    /// (which never inspects stdout/stderr/exitCode) to prove it works at all.
    func testCapturesStdoutStderrAndExitCodeWithProcessGroup() async throws {
        let r = try await SystemCommandRunner().run(
            executable: "sh", arguments: ["-c", "printf out; printf err >&2; exit 3"],
            cwd: URL(fileURLWithPath: "/tmp"), environment: env, processGroup: true, onSpawn: nil)
        XCTAssertEqual(String(decoding: r.stdout, as: UTF8.self), "out")
        XCTAssertEqual(r.stderr, "err")
        XCTAssertEqual(r.exitCode, 3)
    }

    /// Same deadlock risk as `testLargeOutputDoesNotDeadlock`, but for the posix_spawn path's
    /// own pipes — nothing here shares the `Process`-path draining code.
    func testLargeOutputDoesNotDeadlockWithProcessGroup() async throws {
        let r = try await SystemCommandRunner().run(
            executable: "sh", arguments: ["-c", "head -c 2000000 /dev/zero | tr '\\0' a"],
            cwd: URL(fileURLWithPath: "/tmp"), environment: env, processGroup: true, onSpawn: nil)
        XCTAssertEqual(r.stdout.count, 2_000_000)
    }

    /// `onStdout` sees each chunk as the child writes it — the whole point is a live
    /// `runs/<run>/stdout` — so 'a' must arrive while the child is still sleeping, well before
    /// `run` returns, on BOTH spawn paths. The returned stdout stays the whole of it.
    func testStdoutSinkReceivesDataBeforeExitOnBothPaths() async throws {
        final class Chunks: @unchecked Sendable {
            let lock = NSLock(); var items: [(Data, Date)] = []
            func add(_ d: Data) { lock.withLock { items.append((d, Date())) } }
        }
        for processGroup in [false, true] {
            let chunks = Chunks()
            let r = try await SystemCommandRunner().run(
                executable: "sh", arguments: ["-c", "printf a; sleep 0.3; printf b"], cwd: URL(fileURLWithPath: "/tmp"),
                environment: env, processGroup: processGroup, onSpawn: nil, onStdout: { chunks.add($0) })
            let returned = Date()
            XCTAssertEqual(String(decoding: r.stdout, as: UTF8.self), "ab", "processGroup \(processGroup)")
            let first = try XCTUnwrap(chunks.items.first, "processGroup \(processGroup)")
            XCTAssertEqual(String(decoding: first.0, as: UTF8.self), "a", "processGroup \(processGroup)")
            XCTAssertGreaterThan(returned.timeIntervalSince(first.1), 0.2, "'a' arrived only at exit (processGroup \(processGroup))")
            XCTAssertEqual(String(decoding: chunks.items.map(\.0).reduce(Data(), +), as: UTF8.self), "ab")
        }
    }

    /// A runner with no streaming of its own (every test fake) still hands the sink the whole
    /// stdout once, at exit — so a caller can always build its stream file through the sink.
    func testNonStreamingRunnerDeliversStdoutToTheSinkAtExit() async throws {
        struct Canned: CommandRunner {
            func run(executable: String, arguments: [String], cwd: URL, environment: [String: String],
                     processGroup: Bool, onSpawn: (@Sendable (Int32) -> Void)?) async throws -> CommandResult {
                CommandResult(stdout: Data("whole".utf8), stderr: "", exitCode: 0)
            }
        }
        final class Box: @unchecked Sendable { var data = Data() }
        let box = Box()
        _ = try await Canned().run(executable: "x", arguments: [], cwd: URL(fileURLWithPath: "/tmp"), environment: [:],
                                   processGroup: false, onSpawn: nil, onStdout: { box.data.append($0) })
        XCTAssertEqual(String(decoding: box.data, as: UTF8.self), "whole")
    }

    /// The `posix_spawn` path (Task 7's ⏹): a shell that forks two background sleeps, both
    /// outliving the shell itself unless something reaches the whole group. Cancelling with
    /// `processGroup: true` must leave neither alive.
    func testProcessGroupCancellationKillsWholeSubtree() async throws {
        final class PIDBox: @unchecked Sendable { var pid: Int32 = -1 }
        let box = PIDBox()
        let t = Task {
            try await SystemCommandRunner().run(
                executable: "sh", arguments: ["-c", "sleep 30 & sleep 30"],
                cwd: URL(fileURLWithPath: "/tmp"), environment: env,
                processGroup: true, onSpawn: { box.pid = $0 })
        }
        // Give the shell time to fork both sleeps before cancelling.
        try? await Task.sleep(nanoseconds: 300_000_000)
        t.cancel()
        do {
            _ = try await t.value
            XCTFail("expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertGreaterThan(box.pid, 0)

        // The escalation ladder (SIGTERM, then SIGKILL ~1s later if SIGTERM didn't land) needs
        // time to finish before this checks for survivors.
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        let check = Process()
        check.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        check.arguments = ["-g", String(box.pid)]
        check.standardOutput = FileHandle.nullDevice
        check.standardError = FileHandle.nullDevice
        try check.run()
        check.waitUntilExit()
        // `pgrep` exits 1 when nothing matches — anything else means a survivor in the group.
        XCTAssertEqual(check.terminationStatus, 1, "expected no survivors in group \(box.pid)")
    }

    /// ⏹'s SIGTERM must actually land, not wait out the SIGKILL fallback: raw `posix_spawn`
    /// hands the child the spawning thread's signal mask/ignored set unless told otherwise,
    /// and under xctest that left `sleep 30` running through a SIGTERM (observed 1.035s to
    /// die — exactly the SIGKILL delay — before `POSIX_SPAWN_SETSIGDEF|SETSIGMASK`).
    func testProcessGroupCancellationLandsOnSIGTERM() async throws {
        // The shell records the SIGTERM it receives. A child that never saw it died to the
        // SIGKILL fallback a second later, which is what the old wall-clock bound told apart
        // and what a loaded machine blurred.
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("fd-term-\(UUID().uuidString)")
        let ready = FileManager.default.temporaryDirectory.appendingPathComponent("fd-ready-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: marker); try? FileManager.default.removeItem(at: ready) }
        let script = "trap 'echo term > \'\(marker.path)\'; exit 0' TERM; echo up > '\(ready.path)'; sleep 30 & wait"
        let t = Task {
            try await SystemCommandRunner().run(executable: "sh", arguments: ["-c", script], cwd: URL(fileURLWithPath: "/tmp"),
                                                environment: env, processGroup: true, onSpawn: nil)
        }
        var waited = 0
        while !FileManager.default.fileExists(atPath: ready.path), waited < 1000 {
            try await Task.sleep(nanoseconds: 20_000_000); waited += 1
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: ready.path), "the shell installed its trap")
        t.cancel()
        _ = try? await t.value
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path), "SIGTERM reached the child; it did not die to the SIGKILL fallback")
    }

    /// The leader exits on SIGTERM, but a descendant that ignores it and detached its streams
    /// lives on after the leader is reaped. The SIGKILL sweep must reach the group anyway.
    func testCancellationSweepsATermIgnoringDescendantAfterTheLeaderExits() async throws {
        let pidFile = FileManager.default.temporaryDirectory.appendingPathComponent("fd-sweep-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: pidFile) }
        let script = "(trap '' TERM; exec sleep 30) >/dev/null 2>&1 </dev/null & echo $! > '\(pidFile.path)'; wait"
        let t = Task {
            try await SystemCommandRunner().run(executable: "sh", arguments: ["-c", script], cwd: URL(fileURLWithPath: "/tmp"),
                                                environment: env, processGroup: true, onSpawn: nil)
        }
        var waited = 0
        while (try? String(contentsOf: pidFile, encoding: .utf8))?.isEmpty ?? true, waited < 100 {
            try await Task.sleep(nanoseconds: 20_000_000); waited += 1
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        let child = try XCTUnwrap(Int32(try String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        XCTAssertEqual(kill(child, 0), 0, "the descendant is running before ⏹")
        let cancelledAt = Date()
        t.cancel()
        _ = try? await t.value
        while kill(child, 0) == 0, Date().timeIntervalSince(cancelledAt) < 20 { try await Task.sleep(nanoseconds: 20_000_000) }
        let survived = kill(child, 0) == 0
        if survived { kill(child, SIGKILL) }
        XCTAssertFalse(survived, "a TERM-ignoring descendant outlived ⏹ by 20s")
    }

    /// A descriptor the app opened without O_CLOEXEC (a socket, a log, a file a sandbox would
    /// have refused) must not reach the child: through it a sandboxed generator wrote outside its
    /// folder and spoke HTTP.
    func testProcessGroupChildInheritsNoStrayDescriptors() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("fd-leak-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        let fd = open(file.path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        XCTAssertGreaterThan(fd, 2)
        defer { close(fd) }
        let perl = "open(my $f, '>&=', \(fd)) or die \"fd: $!\\n\"; print $f \"leak\\n\" or die \"w: $!\\n\"; close $f or die \"c: $!\\n\""
        let r = try await SystemCommandRunner().run(
            executable: "perl", arguments: ["-e", perl], cwd: URL(fileURLWithPath: "/tmp"),
            environment: env, processGroup: true, onSpawn: nil)
        XCTAssertNotEqual(r.exitCode, 0)
        XCTAssertTrue(r.stderr.contains("Bad file descriptor"), r.stderr)
        XCTAssertEqual(try Data(contentsOf: file).count, 0, "the child wrote through an inherited descriptor")
    }

    /// A double-forked `setsid` child leaves the process group, so no group signal reaches it,
    /// and it keeps the stdout pipe. The run must still end soon after the leader does, and the
    /// holder must be dead. A rescue kills the holder after 15s so a regression fails instead
    /// of hanging the suite.
    func testEscapedPipeHolderCannotStallTheRun() async throws {
        let marker = "\(Int.random(in: 7_000_000...7_999_999))"
        defer { Self.pkill(marker) }
        let script = "perl -MPOSIX -e 'exit 0 if fork; POSIX::setsid(); exit 0 if fork; exec \"/bin/sleep\", \"\(marker)\"'; echo started"
        let rescue = Task { try await Task.sleep(nanoseconds: 15_000_000_000); Self.pkill(marker) }
        defer { rescue.cancel() }
        let start = Date()
        let r = try await SystemCommandRunner().run(executable: "sh", arguments: ["-c", script],
                                                    cwd: URL(fileURLWithPath: "/tmp"), environment: env,
                                                    processGroup: true, onSpawn: nil)
        XCTAssertLessThan(Date().timeIntervalSince(start), 5, "the run waited on the escaped holder")
        XCTAssertEqual(String(decoding: r.stdout, as: UTF8.self), "started\n")
        XCTAssertEqual(r.exitCode, 0)
        // A same-group child's lost late output is never silent.
        XCTAssertTrue(r.stderr.hasSuffix("\n[stopped 1 background processes still holding output]"), r.stderr)
        var waited = 0
        while Self.alive(marker), waited < 100 { try await Task.sleep(nanoseconds: 20_000_000); waited += 1 }
        XCTAssertFalse(Self.alive(marker), "the escaped pipe holder is still running")
    }

    /// stderr is for an error message. A flood of it is drained, so the child never blocks,
    /// but only the head is kept.
    func testStderrIsTruncatedButDrained() async throws {
        let r = try await SystemCommandRunner().run(
            executable: "sh", arguments: ["-c", "head -c 5000000 /dev/zero | tr '\\0' e >&2; printf done"],
            cwd: URL(fileURLWithPath: "/tmp"), environment: env, processGroup: true, onSpawn: nil)
        XCTAssertEqual(String(decoding: r.stdout, as: UTF8.self), "done")
        XCTAssertLessThanOrEqual(r.stderr.utf8.count, SystemCommandRunner.stderrCapture + 64)
        XCTAssertTrue(r.stderr.hasSuffix(SystemCommandRunner.stderrTruncatedNote), String(r.stderr.suffix(80)))
    }

    /// The escapee floods stdout through the grace and the kill. Only `stdoutCapture` bytes
    /// may be kept: before the cap, an escaped `yes` pushed about 1.8 GB into the runner.
    func testEscapedFloodKeepsOnlyTheCapture() async throws {
        let keep = 1 << 20
        let script = "perl -MPOSIX -e 'exit 0 if fork; POSIX::setsid(); exit 0 if fork; exec \"/usr/bin/yes\"'"
        let r = try await SystemCommandRunner().run(executable: "sh", arguments: ["-c", script],
                                                    cwd: URL(fileURLWithPath: "/tmp"), environment: env,
                                                    processGroup: true, onSpawn: nil, onStdout: nil, stdoutCapture: keep)
        XCTAssertLessThanOrEqual(r.stdout.count, keep)
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        print("[measure] testEscapedFloodKeepsOnlyTheCapture kept=\(r.stdout.count) peakRSS=\(usage.ru_maxrss / (1 << 20)) MiB")
    }

    /// No holder, but a sink slower than the grace: the leader is long gone, and the pipe still
    /// has bytes in it. With no writer left EOF is certain, so nothing may be abandoned.
    func testSlowSinkWithNoHolderReceivesEveryByte() async throws {
        let received = Received()
        let r = try await SystemCommandRunner().run(
            executable: "sh", arguments: ["-c", "printf a; sleep 0.2; head -c 10000 /dev/zero"],
            cwd: URL(fileURLWithPath: "/tmp"), environment: env, processGroup: true, onSpawn: nil,
            onStdout: { chunk in
                if received.add(chunk) == 1 { Thread.sleep(forTimeInterval: 2.5) }
            })
        XCTAssertEqual(r.stdout.count, 10_001)
        XCTAssertEqual(received.bytes, 10_001)
        XCTAssertFalse(r.stderr.contains("background processes"), r.stderr)
        XCTAssertFalse(r.stdoutTruncated)
    }

    /// A holder that exits on SIGTERM was asked to stop, not killed; the note says "stopped".
    func testHolderNoteSaysStopped() {
        XCTAssertEqual(SystemCommandRunner.killedHoldersNote(2), "\n[stopped 2 background processes still holding output]")
    }

    /// Stdout dropped past `stdoutCapture` is flagged, on the process-group path and on a fake.
    func testDroppedStdoutIsFlagged() async throws {
        let cut = try await SystemCommandRunner().run(
            executable: "sh", arguments: ["-c", "head -c 100 /dev/zero"], cwd: URL(fileURLWithPath: "/tmp"),
            environment: env, processGroup: true, onSpawn: nil, onStdout: nil, stdoutCapture: 10)
        XCTAssertEqual(cut.stdout.count, 10)
        XCTAssertTrue(cut.stdoutTruncated)
        let whole = try await SystemCommandRunner().run(
            executable: "sh", arguments: ["-c", "head -c 10 /dev/zero"], cwd: URL(fileURLWithPath: "/tmp"),
            environment: env, processGroup: true, onSpawn: nil, onStdout: nil, stdoutCapture: 10)
        XCTAssertFalse(whole.stdoutTruncated)
        let viaProcess = try await SystemCommandRunner().run(
            executable: "sh", arguments: ["-c", "head -c 100 /dev/zero"], cwd: URL(fileURLWithPath: "/tmp"),
            environment: env, processGroup: false, onSpawn: nil, onStdout: nil, stdoutCapture: 10)
        XCTAssertTrue(viaProcess.stdoutTruncated)
    }

    // MARK: - The PIPE_EOF bit, made wrong on purpose

    /// A kernel that never sets PIPE_EOF: the bit reads "writer alive" forever. With no holder
    /// in the scan, EOF is certain, so the drain must not be abandoned (which silently cut a
    /// slow sink's tail).
    func testEOFBitThatIsNeverSetDoesNotAbandonAQuietPipe() {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(pipe(&fds), 0)
        close(fds[1])
        defer { close(fds[0]) }
        let signals = Signals()
        let probe = SystemCommandRunner.PipeProbe(eofBit: { _ in false }, writers: { _ in [] },
                                                  signal: { signals.add($0, $1) })
        let outcome = SystemCommandRunner.killPipeWriters(of: [fds[0]], probe: probe)
        XCTAssertFalse(outcome.writerAlive, "no holder exists, yet the drain would be abandoned")
        XCTAssertEqual(outcome.stopped, 0)
        XCTAssertTrue(signals.all.isEmpty)
    }

    /// A kernel that sets PIPE_EOF while a writer still lives: the scan still sees the holder,
    /// so it gets TERM then KILL, and while it survives the drain may be abandoned (bounded),
    /// never awaited without a limit.
    func testEOFBitSetWhileAWriterLivesStillCountsTheWriter() {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(pipe(&fds), 0)
        defer { close(fds[0]); close(fds[1]) }
        let signals = Signals()
        let holder: pid_t = 999_999
        let probe = SystemCommandRunner.PipeProbe(eofBit: { _ in true }, writers: { _ in [holder] },
                                                  signal: { signals.add($0, $1) })
        let outcome = SystemCommandRunner.killPipeWriters(of: [fds[0]], probe: probe)
        XCTAssertTrue(outcome.writerAlive, "a holder the scan sees was treated as gone")
        XCTAssertEqual(outcome.stopped, 1)
        XCTAssertEqual(signals.all.map(\.signal), [SIGTERM, SIGKILL])
    }

    /// A probe whose bit fails the self-test and whose scan cannot see the holder: the case
    /// in which nothing can say a writer is gone.
    private static let blindProbe = SystemCommandRunner.PipeProbe(eofBit: { _ in nil }, writers: { _ in [] },
                                                                  signal: { _, _ in })

    /// With an untrusted bit and a holder nobody can see, the drain waits at most the limit,
    /// then abandons, and says so. A rescue kills the holder after 15 s so a regression fails.
    func testUnseenHolderWithAnUntrustedBitIsAbandonedAtTheLimit() async throws {
        let marker = "\(Int.random(in: 7_000_000...7_999_999))"
        defer { Self.pkill(marker) }
        let script = "perl -MPOSIX -e 'exit 0 if fork; POSIX::setsid(); exit 0 if fork; exec \"/bin/sleep\", \"\(marker)\"'; echo started"
        let rescue = Task { try await Task.sleep(nanoseconds: 15_000_000_000); Self.pkill(marker) }
        defer { rescue.cancel() }
        let start = Date()
        let r = try await SystemCommandRunner(probe: Self.blindProbe, untrustedDrainLimit: 1).run(
            executable: "sh", arguments: ["-c", script], cwd: URL(fileURLWithPath: "/tmp"), environment: env,
            processGroup: true, onSpawn: nil)
        XCTAssertLessThan(Date().timeIntervalSince(start), 6, "the drain waited on an unseen holder past its limit")
        XCTAssertEqual(String(decoding: r.stdout, as: UTF8.self), "started\n")
        XCTAssertTrue(r.stderr.hasSuffix(SystemCommandRunner.abandonedNote), r.stderr)
    }

    /// The same holder, and the caller's clock runs out first: its cancel must reach the drain
    /// (timeout plus the one-second sweep), not leave it waiting on the holder.
    func testCancelReachesADrainHeldByAnUnseenHolder() async throws {
        let marker = "\(Int.random(in: 7_000_000...7_999_999))"
        defer { Self.pkill(marker) }
        let script = "perl -MPOSIX -e 'exit 0 if fork; POSIX::setsid(); exit 0 if fork; exec \"/bin/sleep\", \"\(marker)\"'; echo started"
        let rescue = Task { try await Task.sleep(nanoseconds: 15_000_000_000); Self.pkill(marker) }
        defer { rescue.cancel() }
        let env = self.env
        let start = Date()
        let work = Task {
            try await SystemCommandRunner(probe: Self.blindProbe, untrustedDrainLimit: 600).run(
                executable: "sh", arguments: ["-c", script], cwd: URL(fileURLWithPath: "/tmp"), environment: env,
                processGroup: true, onSpawn: nil)
        }
        try await Task.sleep(nanoseconds: 2_000_000_000)
        work.cancel()
        do {
            _ = try await work.value
            XCTFail("a cancelled run returned a result")
        } catch is CancellationError {}
        XCTAssertLessThan(Date().timeIntervalSince(start), 6, "the cancel did not reach the drain")
    }

    /// The bit is self-tested once per process; a probe whose bit lies either way is not trusted.
    func testEOFBitSelfTest() {
        XCTAssertTrue(SystemCommandRunner.PipeProbe.system.bitTrusted, "this kernel's PIPE_EOF failed the self-test")
        XCTAssertFalse(SystemCommandRunner.PipeProbe.selfTest { _ in false })
        XCTAssertFalse(SystemCommandRunner.PipeProbe.selfTest { _ in true })
        XCTAssertFalse(SystemCommandRunner.PipeProbe.selfTest { _ in nil })
    }

    /// The holder is asked first: SIGTERM, which an MCP server or an ssh master uses to shut
    /// down cleanly. The trap's marker proves TERM arrived and was handled.
    func testHolderGetsSIGTERMFirst() async throws {
        let marker = "\(Int.random(in: 7_000_000...7_999_999))"
        defer { Self.pkill(marker) }
        let termed = FileManager.default.temporaryDirectory.appendingPathComponent("fd-termed-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: termed) }
        let inner = "trap \"echo term > \(termed.path); exit 0\" TERM; /bin/sleep \(marker) & wait"
        let script = "perl -MPOSIX -e 'exit 0 if fork; POSIX::setsid(); exit 0 if fork; exec \"/bin/sh\", \"-c\", $ARGV[0]' '\(inner)'"
        let rescue = Task { try await Task.sleep(nanoseconds: 15_000_000_000); Self.pkill(marker) }
        defer { rescue.cancel() }
        let r = try await SystemCommandRunner().run(executable: "sh", arguments: ["-c", script],
                                                    cwd: URL(fileURLWithPath: "/tmp"), environment: env,
                                                    processGroup: true, onSpawn: nil)
        XCTAssertEqual(try? String(contentsOf: termed, encoding: .utf8), "term\n", "the holder was not sent SIGTERM first")
        XCTAssertTrue(r.stderr.contains("[stopped "), r.stderr)
    }

    /// A holder that ignores SIGTERM gets SIGKILL half a second later.
    func testTermIgnoringHolderIsKilled() async throws {
        let marker = "\(Int.random(in: 7_000_000...7_999_999))"
        defer { Self.pkill(marker) }
        let script = "perl -MPOSIX -e 'exit 0 if fork; POSIX::setsid(); exit 0 if fork; $SIG{TERM} = \"IGNORE\"; exec \"/bin/sleep\", \"\(marker)\"'"
        let rescue = Task { try await Task.sleep(nanoseconds: 15_000_000_000); Self.pkill(marker) }
        defer { rescue.cancel() }
        let start = Date()
        let r = try await SystemCommandRunner().run(executable: "sh", arguments: ["-c", script],
                                                    cwd: URL(fileURLWithPath: "/tmp"), environment: env,
                                                    processGroup: true, onSpawn: nil)
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
        XCTAssertFalse(Self.alive(marker), "a TERM-ignoring holder survived")
        XCTAssertTrue(r.stderr.hasSuffix("\n[stopped 1 background processes still holding output]"), r.stderr)
    }

    static func pgrep(_ marker: String) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        p.arguments = ["-f", "sleep \(marker)"]
        p.standardOutput = FileHandle.nullDevice
        try? p.run(); p.waitUntilExit()
        return p.terminationStatus
    }

    static func alive(_ marker: String) -> Bool { pgrep(marker) == 0 }

    static func pkill(_ marker: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        p.arguments = ["-9", "-f", "sleep \(marker)"]
        try? p.run(); p.waitUntilExit()
    }
}

/// `GraphReader`'s br-list/br-graph/decode sequence, against the same fixtures
/// `GraphSnapshotTests` decodes directly — this proves the sequencing and failure mapping
/// around `GraphSnapshot.decode`, not the decode itself.
final class GraphReaderTests: XCTestCase {
    private struct FixtureRunner: CommandRunner {
        let replies: [String: (stdout: Data, exitCode: Int32)]
        func run(executable: String, arguments: [String], cwd: URL, environment: [String: String],
                 processGroup: Bool, onSpawn: (@Sendable (Int32) -> Void)?) async throws -> CommandResult {
            let reply = replies[arguments.first ?? ""] ?? (Data(), 127)
            return CommandResult(stdout: reply.stdout, stderr: "", exitCode: reply.exitCode)
        }
    }

    private func load(_ name: String) throws -> Data {
        try Data(contentsOf: try XCTUnwrap(Bundle(for: Self.self).url(
            forResource: name, withExtension: "json", subdirectory: "Fixtures/Intake")))
    }

    func testReadsTheFixturesIntoASnapshot() async throws {
        let list = try load("br-list-all"), graph = try load("br-graph-all")
        let reader = GraphReader(runner: FixtureRunner(replies: ["list": (list, 0), "graph": (graph, 0)]),
                                 environment: [:])
        let snapshot = try await reader.read(project: "/p")
        XCTAssertEqual(snapshot.beads.count, 3)
        XCTAssertEqual(snapshot.beads["t-lqw"]?.assignee, "BlueFalcon")
        XCTAssertEqual(snapshot.edges, [DepEdge(dependent: "t-5mi", dependency: "t-lqw")])
    }

    func testAFailedBrListThrowsBeforeEverRunningBrGraph() async throws {
        let reader = GraphReader(runner: FixtureRunner(replies: ["list": (Data("no such project".utf8), 1)]),
                                 environment: [:])
        do {
            _ = try await reader.read(project: "/p")
            XCTFail("expected GraphReadFailed")
        } catch let failure as GraphReadFailed {
            XCTAssertEqual(failure.command, "br list")
            XCTAssertEqual(failure.exitCode, 1)
            XCTAssertEqual(failure.detail, "no such project")
        }
    }
}

private final class Received: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private var total = 0
    /// Returns the call number, from 1.
    func add(_ chunk: Data) -> Int { lock.lock(); defer { lock.unlock() }; calls += 1; total += chunk.count; return calls }
    var bytes: Int { lock.lock(); defer { lock.unlock() }; return total }
}

/// The signals a fake `PipeProbe` was asked to send, in order.
private final class Signals: @unchecked Sendable {
    private let lock = NSLock()
    private var sent: [(pid: pid_t, signal: Int32)] = []
    func add(_ pid: pid_t, _ signal: Int32) { lock.lock(); sent.append((pid, signal)); lock.unlock() }
    var all: [(pid: pid_t, signal: Int32)] { lock.lock(); defer { lock.unlock() }; return sent }
}
