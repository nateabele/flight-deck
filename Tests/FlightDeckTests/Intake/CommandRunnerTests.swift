import XCTest
import IntakeKit

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
        let t = Task {
            try await SystemCommandRunner().run(executable: "sleep", arguments: ["30"], cwd: URL(fileURLWithPath: "/tmp"),
                                                environment: env, processGroup: true, onSpawn: nil)
        }
        try? await Task.sleep(nanoseconds: 300_000_000)
        let cancelledAt = Date()
        t.cancel()
        _ = try? await t.value
        XCTAssertLessThan(Date().timeIntervalSince(cancelledAt), 0.5)
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
        while kill(child, 0) == 0, Date().timeIntervalSince(cancelledAt) < 1.5 { try await Task.sleep(nanoseconds: 20_000_000) }
        let survived = kill(child, 0) == 0
        if survived { kill(child, SIGKILL) }
        XCTAssertFalse(survived, "a TERM-ignoring descendant outlived ⏹ by 1.5s")
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
