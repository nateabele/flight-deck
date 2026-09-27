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
        /// Sockets with a "readable pidfile" — i.e. what `reap` requires (fix round 1, Review
        /// Focus 1) before it will ever call `terminate`. Deliberately NOT implied by
        /// `liveSockets` membership: the real fd-abduco binds the socket in its launcher before
        /// the daemon proper forks and writes `<socket>.pid`, so tests need to model "live, no
        /// pidfile yet" as its own state.
        var pidfiledSockets: Set<String> = []
        /// Sockets `peerPID(socketPath:)` can recover a pid for even with no pidfile — models
        /// `getsockopt(SOL_LOCAL, LOCAL_PEERPID)` succeeding against a real orphaned daemon
        /// (fix round 2, Review Focus 4).
        var peerPIDsBySocket: [String: pid_t] = [:]
        private(set) var terminatedSockets: [String] = []
        private(set) var terminatedPIDs: [pid_t] = []

        func isLive(_ id: UUID) -> Bool { false }
        func isLive(socketPath: String) -> Bool { liveSockets.contains(socketPath) }
        func daemonPID(_ id: UUID) -> pid_t? { nil }
        func daemonPID(socketPath: String) -> pid_t? { pidfiledSockets.contains(socketPath) ? 4242 : nil }
        func terminate(_ id: UUID) {}
        func terminate(socketPath: String) {
            terminatedSockets.append(socketPath)
            liveSockets.remove(socketPath)
            pidfiledSockets.remove(socketPath)
        }
        func peerPID(socketPath: String) -> pid_t? { peerPIDsBySocket[socketPath] }
        func terminate(pid: pid_t, socketPath: String) {
            terminatedPIDs.append(pid)
            terminatedSockets.append(socketPath)
            liveSockets.remove(socketPath)
            pidfiledSockets.remove(socketPath)
            peerPIDsBySocket.removeValue(forKey: socketPath)
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
        /// Lets a test simulate fd-abduco's own ordering — the socket goes live as a side
        /// effect of the launcher running, before this call even returns — the exact race
        /// Review Focus 1's fix round 1 tests exercise.
        var onSpawn: ((Call) -> Void)?

        func spawn(executable: String, arguments: [String], environment: [String: String]) throws {
            let call = Call(executable: executable, arguments: arguments, environment: environment)
            calls.append(call)
            onSpawn?(call)
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
        environment: @escaping () -> [String: String]? = { ["PATH": "/fake/path"] },
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
            environment: environment,
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
        // The recipe never runs the login-shell lookup itself (see `notReady`); the app's
        // prewarm does, and this stands in for it.
        _ = LoginShellPath.resolve()

        expectSuccess(controller.ensureRunning(UUID()))

        let env = spawner.calls[0].environment
        XCTAssertNil(env["CLAUDECODE"])
        XCTAssertNil(env["CLAUDE_CODE_CHILD_SESSION"])
        XCTAssertEqual(env["FLIGHT_DECK_STATE_DIR"], intakesRoot.deletingLastPathComponent().path)
        XCTAssertNotNil(env["PATH"])
    }

    /// A live socket with a fresh heartbeat is adopted, not respawned — `tape.status` is not
    /// consulted at all (fix round 1, Review Focus 3): see `testStaleHeartbeatOnARunningStatus
    /// TapeGetsReapedAndRespawned` for the case that used to (wrongly) matter on `status` alone.
    func testLiveRunnerIsAdoptedNotRespawned() throws {
        let fixed = Date(timeIntervalSince1970: 1_000_000)
        let fixture = try makeFixture(now: { fixed })
        let id = UUID()
        fixture.control.liveSockets.insert(fixture.controller.socketPath(for: id))
        try saveTape(Tape(status: .running, heartbeat: fixed), for: id, intakesRoot: fixture.intakesRoot)

        let result = fixture.controller.ensureRunning(id)

        expectSuccess(result)
        XCTAssertEqual(fixture.spawner.calls.count, 0, "a running runner must never be respawned")
        XCTAssertEqual(fixture.control.terminatedSockets.count, 0)
    }

    /// Review Focus 3 (fix round 1): `status == .running` on its own must never be trusted — a
    /// runner that crashed mid-round leaves exactly this tape behind (status still `.running`,
    /// heartbeat stale), and adopting it forever would mean nothing ever restarts it. Past
    /// `staleGrace` from the first sighting (fix round 2, Review Focus 1 — see
    /// `testStaleHeartbeatWithAliveDaemonSurvivesUntilStaleGraceElapses` for the "not yet" half
    /// of this same check), it is reaped and respawned.
    func testStaleHeartbeatOnARunningStatusTapeGetsReapedAndRespawned() throws {
        var current = Date(timeIntervalSince1970: 1_000_000)
        let fixture = try makeFixture(now: { current })
        let id = UUID()
        let socket = fixture.controller.socketPath(for: id)
        fixture.control.liveSockets.insert(socket)
        fixture.control.pidfiledSockets.insert(socket)
        try saveTape(
            Tape(status: .running, heartbeat: current.addingTimeInterval(-60)), for: id,
            intakesRoot: fixture.intakesRoot
        )

        // First sighting of the stale heartbeat: within `staleGrace`, so still (provisionally)
        // running.
        XCTAssertTrue(fixture.controller.isRunning(id))

        current = current.addingTimeInterval(21)
        XCTAssertFalse(fixture.controller.isRunning(id))

        let result = fixture.controller.ensureRunning(id)

        expectSuccess(result)
        XCTAssertEqual(fixture.control.terminatedSockets, [socket], "the stale daemon must be reaped first")
        XCTAssertEqual(fixture.spawner.calls.count, 1, "a fresh runner must be spawned after reaping it")
    }

    /// Review Focus 1 (critical, fix round 1): fd-abduco binds and listens on the socket in its
    /// launcher before the runner underneath has written anything — so a second `ensureRunning`
    /// landing right after the first, with a live socket and a tape that still looks idle, must
    /// never see that as "finished" and spawn a competing runner on the same tape.
    func testDoubleEnsureRunningWithinGraceSpawnsOnlyOnce() throws {
        let fixture = try makeFixture()
        let id = UUID()
        let socket = fixture.controller.socketPath(for: id)
        // Simulates fd-abduco's own ordering: the socket is live as a side effect of the
        // launcher running, well before the runner has written a heartbeat or moved off `.idle`.
        fixture.spawner.onSpawn = { _ in fixture.control.liveSockets.insert(socket) }
        try saveTape(Tape(status: .idle), for: id, intakesRoot: fixture.intakesRoot)

        expectSuccess(fixture.controller.ensureRunning(id))
        expectSuccess(fixture.controller.ensureRunning(id))

        XCTAssertEqual(fixture.spawner.calls.count, 1, "the second call must adopt, not respawn")
        XCTAssertTrue(fixture.control.terminatedSockets.isEmpty, "a runner still in its grace period must never be reaped")
    }

    /// Same race as above, aimed at `reap` directly: called on its own (not via `ensureRunning`)
    /// inside the grace period, it must still be a no-op.
    func testReapIsANoOpWithinTheSpawnGracePeriod() throws {
        let fixture = try makeFixture()
        let id = UUID()
        let socket = fixture.controller.socketPath(for: id)
        fixture.spawner.onSpawn = { _ in fixture.control.liveSockets.insert(socket) }
        try saveTape(Tape(status: .idle), for: id, intakesRoot: fixture.intakesRoot)
        expectSuccess(fixture.controller.ensureRunning(id))

        fixture.controller.reap(id)

        XCTAssertTrue(fixture.control.terminatedSockets.isEmpty)
    }

    /// Review Focus 1's other half: even outside the grace period, `reap` must never unlink a
    /// live socket it cannot confirm has a real pid behind it — that would orphan a daemon
    /// mid-fork rather than kill it. No pidfile yet (only `liveSockets`, not `pidfiledSockets`)
    /// must leave the socket alone.
    func testReapNeverTerminatesALiveSocketWithNoReadablePidfile() throws {
        let fixture = try makeFixture()
        let id = UUID()
        let socket = fixture.controller.socketPath(for: id)
        fixture.control.liveSockets.insert(socket)
        try saveTape(Tape(status: .stopped), for: id, intakesRoot: fixture.intakesRoot)

        fixture.controller.reap(id)

        XCTAssertTrue(fixture.control.terminatedSockets.isEmpty)
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

    /// Fix round 2, Review Focus 1: right after the Mac wakes from sleep, a perfectly healthy
    /// runner's heartbeat is exactly as old as the sleep — one stale reading must not reap it
    /// while its daemon pid is still provably alive, only a reading that is STILL stale
    /// `staleGrace` after the first sighting.
    func testStaleHeartbeatWithAliveDaemonSurvivesUntilStaleGraceElapses() throws {
        var current = Date(timeIntervalSince1970: 1_000_000)
        let fixture = try makeFixture(now: { current })
        let id = UUID()
        let socket = fixture.controller.socketPath(for: id)
        fixture.control.liveSockets.insert(socket)
        fixture.control.pidfiledSockets.insert(socket)
        try saveTape(Tape(status: .running, heartbeat: current), for: id, intakesRoot: fixture.intakesRoot)

        // The heartbeat goes stale (past `heartbeatFreshness`) — this is the FIRST sighting.
        // Within `staleGrace` (default 20s) of it, a healthy mid-sleep runner must survive.
        current = current.addingTimeInterval(11)
        let firstResult = fixture.controller.ensureRunning(id)
        expectSuccess(firstResult)
        XCTAssertTrue(fixture.control.terminatedSockets.isEmpty, "one stale reading must never reap a live daemon")
        XCTAssertEqual(fixture.spawner.calls.count, 0)

        // Still stale 21s after the FIRST sighting (not the heartbeat itself) — past the
        // default 20s `staleGrace` — now it is genuinely treated as crashed and respawned.
        current = current.addingTimeInterval(21)
        let secondResult = fixture.controller.ensureRunning(id)
        expectSuccess(secondResult)
        XCTAssertEqual(fixture.control.terminatedSockets, [socket])
        XCTAssertEqual(fixture.spawner.calls.count, 1)
    }

    /// The other half of Review Focus 1: a fresh heartbeat arriving before `staleGrace` elapses
    /// clears the grace entirely, so a LATER stale reading starts its own grace rather than
    /// inheriting the earlier sighting's clock.
    func testFreshHeartbeatAfterAStaleSightingClearsTheGrace() throws {
        var current = Date(timeIntervalSince1970: 1_000_000)
        let fixture = try makeFixture(now: { current })
        let id = UUID()
        let socket = fixture.controller.socketPath(for: id)
        fixture.control.liveSockets.insert(socket)
        fixture.control.pidfiledSockets.insert(socket)
        let store = TapeStore(intakeDirectory: IntakeStore(root: fixture.intakesRoot).directory(for: id))
        try store.saveTape(Tape(status: .running, heartbeat: current))

        current = current.addingTimeInterval(11)      // stale — first sighting, within grace
        XCTAssertTrue(fixture.controller.isRunning(id))

        // The runner catches up and writes a fresh heartbeat before `staleGrace` elapses.
        try store.saveTape(Tape(status: .running, heartbeat: current))
        XCTAssertTrue(fixture.controller.isRunning(id))

        // Long after the ORIGINAL stale sighting: if that sighting were still being counted,
        // this would now read as crashed even though the heartbeat is fresh again.
        current = current.addingTimeInterval(30)
        try store.saveTape(Tape(status: .running, heartbeat: current))
        let result = fixture.controller.ensureRunning(id)

        expectSuccess(result)
        XCTAssertTrue(fixture.control.terminatedSockets.isEmpty)
        XCTAssertEqual(fixture.spawner.calls.count, 0)
    }

    /// Fix round 2, Review Focus 2: `spawnedAt` must be recorded BEFORE `spawn()` is even
    /// called, not after it returns — `fd-abduco` can bind the socket as a side effect of the
    /// launcher running, and a re-entrant `ensureRunning` landing inside that call (a timer
    /// tick, a user action) must already see this one as running.
    func testSpawnedAtIsRecordedBeforeSpawnCompletes() throws {
        let fixture = try makeFixture()
        let id = UUID()
        let socket = fixture.controller.socketPath(for: id)
        var sawRunningDuringSpawn = false
        fixture.spawner.onSpawn = { _ in
            fixture.control.liveSockets.insert(socket)
            sawRunningDuringSpawn = fixture.controller.isRunning(id)
        }
        try saveTape(Tape(status: .idle), for: id, intakesRoot: fixture.intakesRoot)

        expectSuccess(fixture.controller.ensureRunning(id))

        XCTAssertTrue(
            sawRunningDuringSpawn, "spawnedAt must be recorded before spawn() runs, not after it returns"
        )
    }

    /// A launcher that never exited within its own timeout may still be alive and about to
    /// bind the socket — the grace `ensureRunning` recorded before calling `spawn` must survive
    /// that failure, not just a successful one.
    func testTimedOutLauncherKeepsTheSpawnGrace() throws {
        let fixture = try makeFixture()
        fixture.spawner.errorToThrow = FdAbducoRunnerSpawner.SpawnError.timedOut
        let id = UUID()
        // Models the launcher having bound the socket even though this call gave up on it.
        fixture.control.liveSockets.insert(fixture.controller.socketPath(for: id))

        let result = fixture.controller.ensureRunning(id)

        switch result {
        case .success: XCTFail("expected a spawn failure")
        case .failure(.spawnFailed): break
        case .failure(let other): XCTFail("expected .spawnFailed, got \(other)")
        }
        XCTAssertTrue(fixture.controller.isRunning(id), "a timed-out launcher may still be alive; the grace must survive it")
    }

    /// The complementary case: a launcher that DEFINITELY failed to start (a clean nonzero
    /// exit) never bound anything, so its grace entry must not linger and block the next
    /// `ensureRunning` from trying again immediately.
    func testLauncherFailureClearsTheSpawnGrace() throws {
        let fixture = try makeFixture()
        fixture.spawner.errorToThrow = FdAbducoRunnerSpawner.SpawnError.launcherFailed(1)
        let id = UUID()

        _ = fixture.controller.ensureRunning(id)

        XCTAssertFalse(
            fixture.controller.isRunning(id), "a launcher that never started must not be trusted as running"
        )
    }

    /// Fix round 2, Review Focus 4: a socket that stays live with no pidfile ever appearing —
    /// the launcher bound it, then crashed before its daemon forked and wrote one — used to be
    /// stuck forever under fix round 1's "never terminate without a readable pidfile" rule.
    /// Past `orphanGrace`, `reap` recovers the daemon's real pid straight from the kernel
    /// (`peerPID`, standing in for `getsockopt(SOL_LOCAL, LOCAL_PEERPID)`) and terminates by it.
    func testOrphanedSocketPastGraceIsRecoveredViaPeerPIDAndTerminated() throws {
        var current = Date(timeIntervalSince1970: 1_000_000)
        let fixture = try makeFixture(now: { current })
        let id = UUID()
        let socket = fixture.controller.socketPath(for: id)
        fixture.control.liveSockets.insert(socket)
        fixture.control.peerPIDsBySocket[socket] = 9999
        try saveTape(Tape(status: .stopped), for: id, intakesRoot: fixture.intakesRoot)

        // Within `orphanGrace` (default 30s): a launcher that just bound the socket deserves a
        // chance to write its pidfile before this gives up on it entirely.
        fixture.controller.reap(id)
        XCTAssertTrue(fixture.control.terminatedSockets.isEmpty)

        // Past `orphanGrace` with the pidfile STILL never appearing.
        current = current.addingTimeInterval(31)
        fixture.controller.reap(id)

        XCTAssertEqual(fixture.control.terminatedPIDs, [9999])
        XCTAssertEqual(fixture.control.terminatedSockets, [socket])
    }

    /// If even the kernel can't answer (the process died between `isLive` and `connect()`),
    /// `reap` must leave the socket alone rather than terminate nothing and call it done.
    func testOrphanedSocketWithNoRecoverablePeerPIDIsLeftForTheNextAttempt() throws {
        var current = Date(timeIntervalSince1970: 1_000_000)
        let fixture = try makeFixture(now: { current })
        let id = UUID()
        let socket = fixture.controller.socketPath(for: id)
        fixture.control.liveSockets.insert(socket)
        try saveTape(Tape(status: .stopped), for: id, intakesRoot: fixture.intakesRoot)

        current = current.addingTimeInterval(31)
        fixture.controller.reap(id)

        XCTAssertTrue(fixture.control.terminatedSockets.isEmpty, "nothing to signal, so leave the socket for a later attempt")
    }

    /// The environment isn't ready (the login-shell PATH is still being looked up off the main
    /// actor): nothing is spawned and no spawn grace is recorded, so the next tick's call —
    /// once it is ready — spawns for real instead of trusting a runner that was never started.
    func testEnvironmentNotReadyDefersTheSpawn() throws {
        var ready = false
        let fixture = try makeFixture(environment: { ready ? ["PATH": "/fake/path"] : nil })
        let id = UUID()

        expectFailure(fixture.controller.ensureRunning(id), .notReady)
        XCTAssertEqual(fixture.spawner.calls.count, 0)
        XCTAssertFalse(fixture.controller.isRunning(id))

        ready = true
        expectSuccess(fixture.controller.ensureRunning(id))
        XCTAssertEqual(fixture.spawner.calls.count, 1)
    }

    /// A caller that already decoded the tape hands it over, and `isRunning` judges that one
    /// rather than reading `tape.json` again.
    func testIsRunningUsesTheCallersTape() throws {
        var current = Date(timeIntervalSince1970: 1_000_000)
        let fixture = try makeFixture(now: { current })
        let id = UUID()
        let socket = fixture.controller.socketPath(for: id)
        fixture.control.liveSockets.insert(socket)
        fixture.control.pidfiledSockets.insert(socket)
        try saveTape(Tape(status: .running), for: id, intakesRoot: fixture.intakesRoot) // no heartbeat on disk
        current = current.addingTimeInterval(1)

        XCTAssertFalse(fixture.controller.isRunning(id))
        XCTAssertTrue(fixture.controller.isRunning(id, tape: Tape(status: .running, heartbeat: current)))
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
        fixture.control.pidfiledSockets.insert(socket)
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
        fixture.control.pidfiledSockets.insert(socket)
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
        // The real pid, not the launcher's — proves `daemonPID(socketPath:)` (what `reap` now
        // requires before it will ever terminate anything, fix round 1 Review Focus 1) sees the
        // same live pidfile a real fd-abduco run produces, not just a fake's stand-in.
        let pid = try waitForPidfile(socketPath + ".pid")
        XCTAssertEqual(control.daemonPID(socketPath: socketPath), pid)

        control.terminate(socketPath: socketPath)

        XCTAssertFalse(control.isLive(socketPath: socketPath))
        XCTAssertFalse(FileManager.default.fileExists(atPath: socketPath))
        XCTAssertNotEqual(kill(pid, 0), 0, "terminate must actually kill the daemon, not just unlink its socket")
    }

    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            usleep(20_000)
        }
        return condition()
    }

    /// Polls for the pidfile `fd-abduco` writes at session creation, mirroring
    /// `DaemonControlTests.waitForPidfile` — the daemon proper forks and re-parents after the
    /// launcher this test already waited on, so the pidfile can lag the launcher's own exit.
    private func waitForPidfile(_ path: String) throws -> pid_t {
        for _ in 0..<40 {
            if let contents = try? String(contentsOfFile: path, encoding: .utf8),
                let value = Int32(contents.trimmingCharacters(in: .whitespacesAndNewlines))
            {
                return pid_t(value)
            }
            usleep(50_000)
        }
        throw TimeoutError(message: "pidfile never appeared at \(path)")
    }

    private struct TimeoutError: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }
}
