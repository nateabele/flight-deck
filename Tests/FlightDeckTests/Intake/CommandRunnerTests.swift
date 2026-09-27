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
