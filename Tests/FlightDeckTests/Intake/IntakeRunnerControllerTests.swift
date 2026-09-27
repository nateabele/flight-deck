// Tests/FlightDeckTests/Intake/IntakeRunnerControllerTests.swift
import Darwin
import Foundation
import XCTest
import IntakeKit
@testable import FlightDeck

/// Task 10: the app-side controller that spawns, adopts and reaps a detached intake runner
/// under `fd-abduco`. `flightdeck intake run` and `IntakeRunner` (Tasks 7-9) don't exist yet —
/// every test here drives a fake `RunnerSpawning`/`DaemonControlling`, except the last, which
/// proves the real `fd-abduco` mechanics against a throwaway `sh -c 'sleep 30'`.
@MainActor
final class IntakeRunnerControllerTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        // Space-free and short, for the same `sun_path` reason `DaemonControlTests` gives: the
        // default `FileManager.temporaryDirectory` (`/var/folders/.../T/`) plus a descriptive
        // subdirectory name already exceeds the 104-byte `sun_path` cap before a socket file
        // name is even appended, so the real fd-abduco integration test below would silently
        // target a truncated path. An 8-character suffix is still unique enough for parallel runs.
        tempDir = URL(fileURLWithPath: "/tmp/irc-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        try super.tearDownWithError()
    }

    // MARK: - Fixture

    private final class FakeDaemonControl: DaemonControlling {
        var liveSockets: Set<String> = []
        private(set) var terminatedSockets: [String] = []

        func isLive(_ id: UUID) -> Bool { false }
        func isLive(socketPath: String) -> Bool { liveSockets.contains(socketPath) }
        func daemonPID(_ id: UUID) -> pid_t? { nil }
        func terminate(_ id: UUID) {}
        func terminate(socketPath: String) {
            terminatedSockets.append(socketPath)
            liveSockets.remove(socketPath)
        }
        func stop(_ id: UUID) {}
        func cont(_ id: UUID) {}
    }

    private final class FakeSpawner: RunnerSpawning {
        struct Call {
            let executable: String
            let arguments: [String]
            let environment: [String: String]
        }
        private(set) var calls: [Call] = []
        var errorToThrow: Error?

        func spawn(executable: String, arguments: [String], environment: [String: String]) throws {
            calls.append(Call(executable: executable, arguments: arguments, environment: environment))
            if let errorToThrow { throw errorToThrow }
        }
    }

    private struct Fixture {
        let controller: IntakeRunnerController
        let control: FakeDaemonControl
        let spawner: FakeSpawner
        let daemon: SessionDaemon
        let intakesRoot: URL
    }

    /// `intakesRoot` is `<tempDir>/state/intakes`, so `FLIGHT_DECK_STATE_DIR` (its parent) is
    /// `<tempDir>/state` — mirroring `SessionStore.resolvedIntakesRoot`'s real `<state
    /// dir>/intakes` layout.
    private func makeFixture(
        flightdeckPath: (() -> String?)? = nil,
        now: @escaping () -> Date = Date.init
    ) throws -> Fixture {
        let daemonDir = tempDir.appendingPathComponent("daemon")
        let fakeBinary = tempDir.appendingPathComponent("fake-fd-abduco")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: fakeBinary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeBinary.path)
        let daemon = SessionDaemon(directory: daemonDir, bundledBinary: fakeBinary)

        let intakesRoot = tempDir.appendingPathComponent("state/intakes")
        let control = FakeDaemonControl()
        let spawner = FakeSpawner()
        let controller = IntakeRunnerController(
            daemon: daemon, control: control, spawner: spawner,
            flightdeckPath: flightdeckPath ?? { "/fake/flightdeck" },
            intakesRoot: intakesRoot,
            environment: { ["PATH": "/fake/path"] },
            now: now
        )
        return Fixture(
            controller: controller, control: control, spawner: spawner, daemon: daemon, intakesRoot: intakesRoot
        )
    }

    private func saveTape(_ tape: Tape, for id: UUID, intakesRoot: URL) throws {
        let dir = IntakeStore(root: intakesRoot).directory(for: id)
        try TapeStore(intakeDirectory: dir).saveTape(tape)
    }

    private func expectSuccess(
        _ result: Result<Void, RunnerStartError>, _ message: String = "", file: StaticString = #filePath,
        line: UInt = #line
    ) {
        if case .failure(let error) = result {
            XCTFail("expected success, got \(error) \(message)", file: file, line: line)
        }
    }

    private func expectFailure(
        _ result: Result<Void, RunnerStartError>, _ expected: RunnerStartError, file: StaticString = #filePath,
        line: UInt = #line
    ) {
        switch result {
        case .success:
            XCTFail("expected .failure(\(expected)), got .success", file: file, line: line)
        case .failure(let error):
            XCTAssertEqual(error, expected, file: file, line: line)
        }
    }

    // MARK: - Tests

    func testSpawnArguments() throws {
        let fixture = try makeFixture()
        let id = UUID()

        let result = fixture.controller.ensureRunning(id)

        expectSuccess(result)
        XCTAssertEqual(fixture.spawner.calls.count, 1)
        let call = fixture.spawner.calls[0]
        XCTAssertTrue(call.executable.hasSuffix("/fd-abduco"), call.executable)
        XCTAssertEqual(
            call.arguments,
            [
                "-n", fixture.controller.socketPath(for: id), "/fake/flightdeck", "intake", "run",
                id.uuidString.lowercased(), "--root", fixture.intakesRoot.path,
            ]
        )
        XCTAssertEqual(call.environment, ["PATH": "/fake/path"])
    }

    /// The default `environment` recipe, exercised end to end: repaired PATH, no Claude
    /// child-session identity, `FLIGHT_DECK_STATE_DIR` at the intakes root's parent.
    func testDefaultEnvironmentStripsClaudeIdentityAndSetsStateDir() throws {
        let daemonDir = tempDir.appendingPathComponent("daemon")
        let fakeBinary = tempDir.appendingPathComponent("fake-fd-abduco")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: fakeBinary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeBinary.path)
        let daemon = SessionDaemon(directory: daemonDir, bundledBinary: fakeBinary)
        let intakesRoot = tempDir.appendingPathComponent("state/intakes")
        let control = FakeDaemonControl()
        let spawner = FakeSpawner()
        let controller = IntakeRunnerController(
            daemon: daemon, control: control, spawner: spawner,
            flightdeckPath: { "/fake/flightdeck" }, intakesRoot: intakesRoot
        )

        expectSuccess(controller.ensureRunning(UUID()))

        let env = spawner.calls[0].environment
        XCTAssertNil(env["CLAUDECODE"])
        XCTAssertNil(env["CLAUDE_CODE_CHILD_SESSION"])
        XCTAssertEqual(env["FLIGHT_DECK_STATE_DIR"], intakesRoot.deletingLastPathComponent().path)
        XCTAssertNotNil(env["PATH"])
    }

    func testLiveRunnerIsAdoptedNotRespawned() throws {
        let fixture = try makeFixture()
        let id = UUID()
        fixture.control.liveSockets.insert(fixture.controller.socketPath(for: id))
        try saveTape(Tape(status: .running), for: id, intakesRoot: fixture.intakesRoot)

        let result = fixture.controller.ensureRunning(id)

        expectSuccess(result)
        XCTAssertEqual(fixture.spawner.calls.count, 0, "a running runner must never be respawned")
        XCTAssertEqual(fixture.control.terminatedSockets.count, 0)
    }

    /// A live socket whose heartbeat is fresh counts as running even if `status` has not (yet)
    /// been observed as `.running` — see `isRunning`'s doc comment.
    func testFreshHeartbeatCountsAsRunningEvenWithStaleStatus() throws {
        let fixed = Date(timeIntervalSince1970: 1_000_000)
        let fixture = try makeFixture(now: { fixed })
        let id = UUID()
        fixture.control.liveSockets.insert(fixture.controller.socketPath(for: id))
        try saveTape(
            Tape(status: .idle, heartbeat: fixed.addingTimeInterval(-5)), for: id, intakesRoot: fixture.intakesRoot
        )

        XCTAssertTrue(fixture.controller.isRunning(id))
    }

    func testMissingCLIReportsNoBundledCLI() throws {
        let fixture = try makeFixture(flightdeckPath: { nil })

        let result = fixture.controller.ensureRunning(UUID())

        expectFailure(result, .noBundledCLI)
        XCTAssertEqual(fixture.spawner.calls.count, 0)
    }

    func testMissingFdAbducoBinaryReportsNoFdAbduco() throws {
        let daemon = SessionDaemon(directory: tempDir.appendingPathComponent("daemon"), bundledBinary: nil)
        let intakesRoot = tempDir.appendingPathComponent("state/intakes")
        let control = FakeDaemonControl()
        let spawner = FakeSpawner()
        let controller = IntakeRunnerController(
            daemon: daemon, control: control, spawner: spawner,
            flightdeckPath: { "/fake/flightdeck" }, intakesRoot: intakesRoot,
            environment: { [:] }
        )

        expectFailure(controller.ensureRunning(UUID()), .noFdAbduco)
        XCTAssertEqual(spawner.calls.count, 0)
    }

    func testFinishedRunnerIsReaped() throws {
        let fixture = try makeFixture()
        let id = UUID()
        let socket = fixture.controller.socketPath(for: id)
        fixture.control.liveSockets.insert(socket)
        try saveTape(Tape(status: .stopped), for: id, intakesRoot: fixture.intakesRoot)

        fixture.controller.reap(id)

        XCTAssertEqual(fixture.control.terminatedSockets, [socket])
    }

    /// `ensureRunning` reaps a finished runner's stale socket before spawning a fresh one, so
    /// the new `fd-abduco -n <sock> …` isn't handed a path an old daemon still occupies.
    func testEnsureRunningReapsAFinishedRunnerBeforeRespawning() throws {
        let fixture = try makeFixture()
        let id = UUID()
        let socket = fixture.controller.socketPath(for: id)
        fixture.control.liveSockets.insert(socket)
        try saveTape(Tape(status: .failed), for: id, intakesRoot: fixture.intakesRoot)

        let result = fixture.controller.ensureRunning(id)

        expectSuccess(result)
        XCTAssertEqual(fixture.control.terminatedSockets, [socket])
        XCTAssertEqual(fixture.spawner.calls.count, 1)
    }

    func testSpawnFailureIsReported() throws {
        let fixture = try makeFixture()
        fixture.spawner.errorToThrow = FdAbducoRunnerSpawner.SpawnError.launcherFailed(1)

        let result = fixture.controller.ensureRunning(UUID())

        switch result {
        case .success: XCTFail("expected a spawn failure")
        case .failure(.spawnFailed): break
        case .failure(let other): XCTFail("expected .spawnFailed, got \(other)")
        }
    }

    /// `SessionDaemon.liveSessionIDs()` is what a launch reconcile walks to find daemons whose
    /// *session* did not come back — an intake runner's socket must never parse as one of those
    /// session ids, or the reconcile would try to adopt or reap a tab that never existed.
    func testSocketNameIsInvisibleToSessionReconcile() throws {
        let fixture = try makeFixture()
        let id = UUID()
        let socketPath = fixture.controller.socketPath(for: id)
        FileManager.default.createFile(atPath: socketPath, contents: nil)

        XCTAssertEqual(fixture.daemon.liveSessionIDs(), [])
    }

    // MARK: - Real fd-abduco integration

    /// Against the real `fd-abduco` binary (`vendor/fd-abduco-artifacts/fd-abduco`), not a
    /// fake: `FdAbducoRunnerSpawner` launches `fd-abduco -n <sock> sh -c 'sleep 30'`, and this
    /// proves `isLive(socketPath:)`/`terminate(socketPath:)` see and tear down that real daemon
    /// exactly the way `IntakeRunnerController` will see and tear down a real runner. Skipped
    /// rather than built here — `DaemonControlTests` already covers building it; this only
    /// needs it to exist.
    func testRealFdAbducoSpawnAndTerminate() throws {
        let binaryPath = "vendor/fd-abduco-artifacts/fd-abduco"
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: binaryPath),
            "fd-abduco not built; run scripts/build-fd-abduco.sh first"
        )
        let resolvedBinary = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(binaryPath).path

        let socketPath = tempDir.appendingPathComponent("real.sock").path
        let control = PosixDaemonControl(daemon: SessionDaemon(directory: tempDir, bundledBinary: nil))
        let spawner = FdAbducoRunnerSpawner()

        try spawner.spawn(
            executable: resolvedBinary, arguments: ["-n", socketPath, "sh", "-c", "sleep 30"],
            environment: ProcessInfo.processInfo.environment
        )
        // Must never be leaked: this worktree's process table is shared with other sessions,
        // and `terminate` is idempotent, so running it again below (for the assertion) after
        // this `defer` also runs is harmless — but this is what bounds the daemon's lifetime
        // even if an assertion between here and there fails first.
        defer { control.terminate(socketPath: socketPath) }
        // Poll rather than assume instant: the launcher `spawn` waited for has already exited
        // by the time this runs, but liveness is a real `connect()` against the daemon it
        // exec'd, not a synchronous consequence of that exit.
        XCTAssertTrue(waitUntil(timeout: 2) { control.isLive(socketPath: socketPath) })

        control.terminate(socketPath: socketPath)

        XCTAssertFalse(control.isLive(socketPath: socketPath))
        XCTAssertFalse(FileManager.default.fileExists(atPath: socketPath))
    }

    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            usleep(20_000)
        }
        return condition()
    }
}
