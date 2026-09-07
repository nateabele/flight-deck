// Tests/FlightDeckTests/DaemonLifecycleTests.swift
import XCTest
@testable import FlightDeck

// `StubProvider` lives in its own file now — see that file's doc comment.

/// Task 7: a tab close has to end the daemon (and the agent still attached to it), a launch
/// has to reap daemons whose session did not come back, and quitting must never touch a
/// daemon at all — that persistence is the whole feature. `SessionDaemon`/`DaemonControlling`
/// are already covered on their own; this only checks the lifecycle wiring.

/// A minimal scripted process table, matching `SessionCloseReapTests`' own `FakeInspector` —
/// this file never exercises the reaper's escalation ladder, only whether a daemon gets
/// terminated at the right moments relative to it.
private final class FakeInspector: ProcessInspecting, @unchecked Sendable {
    var living: Set<pid_t>
    init(living: Set<pid_t> = []) { self.living = living }
    func children(of ppid: pid_t) -> Set<pid_t> { [] }
    func descendants(of pid: pid_t) -> [ProcessIdentity] { [] }
    func startTime(of pid: pid_t) -> UInt64? { living.contains(pid) ? 100 : nil }
    func isAlive(_ identity: ProcessIdentity) -> Bool {
        living.contains(identity.pid) && identity.procStart == 100
    }
    func pgid(of pid: pid_t) -> pid_t? { nil }
}

/// Records signals instead of touching a real process — same rule `SessionCloseReapTests` and
/// `QuitReapTests` enforce: nothing reachable from a test may construct `PosixSignals`.
private final class SpySignals: SignalSending, @unchecked Sendable {
    var onSend: ((pid_t) -> Void)?
    func send(_ signal: Int32, toGroup pgid: pid_t) -> Bool { onSend?(pgid); return true }
    func send(_ signal: Int32, toProcess pid: pid_t) -> Bool { onSend?(pid); return true }
    func ownProcessGroup() -> pid_t { 999 }
}

/// Sleeps not at all, so a ladder that does run finishes instantly instead of taking up to
/// 5 s per rung.
private final class InstantSleeper: ReaperSleeping, @unchecked Sendable {
    func sleep(seconds: Double) async {}
}

/// A `DaemonControlling` that records every `terminate` call it receives, in order, and never
/// answers `isLive` truthfully — every test here drives `SessionStore` down the cold-create /
/// graceful-degradation path on purpose, since none of them are testing launch, only teardown.
private final class RecordingDaemonControl: DaemonControlling, @unchecked Sendable {
    private(set) var terminatedIDs: [UUID] = []
    var onTerminate: ((UUID) -> Void)?
    func isLive(_ id: UUID) -> Bool { false }
    func daemonPID(_ id: UUID) -> pid_t? { nil }
    func terminate(_ id: UUID) {
        terminatedIDs.append(id)
        onTerminate?(id)
    }
}

private final class FakePersistence: SessionPersisting {
    var stored: SessionSnapshot?
    func load() -> SessionSnapshot? { stored }
    func save(_ snapshot: SessionSnapshot) { stored = snapshot }
}

@MainActor
final class DaemonLifecycleTests: XCTestCase {
    /// Let the detached reap `Task` `closeSession` schedules run to completion — same
    /// technique as `SessionCloseReapTests.drainMainQueue()`.
    private func drainMainQueue() {
        let exp = expectation(description: "drain")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)
    }

    // MARK: - closeSession terminates the daemon, after the client reap

    /// The behavior Task 7 exists to add: closing a tab must end its daemon, and only after
    /// the client shell has actually detached — `daemonControl.terminate` firing first (or
    /// concurrently, racing the signal) would kill the agent's home out from under a client
    /// that has not let go of it yet.
    func testCloseSessionTerminatesTheDaemonExactlyOnceAfterTheClientReap() {
        var events: [String] = []
        let inspector = FakeInspector(living: [31337])
        let signals = SpySignals()
        signals.onSend = { pid in
            events.append("client reap signal")
            inspector.living.remove(pid)
        }
        let control = RecordingDaemonControl()
        control.onTerminate = { _ in events.append("daemon terminate") }
        let store = SessionStore(
            provider: StubProvider(),
            persistence: nil,
            reaper: SessionReaper(
                inspector: inspector, signals: signals, sleeper: InstantSleeper()
            ),
            daemonControl: control
        )
        store.processInspector = inspector
        let session = store.newSession(in: URL(fileURLWithPath: "/tmp"))
        store.processRegistry.restore([
            session.id: SessionProcess(identity: ProcessIdentity(pid: 31337, procStart: 100))
        ])

        store.closeSession(session.id)
        drainMainQueue()

        XCTAssertEqual(control.terminatedIDs, [session.id])
        XCTAssertEqual(
            events, ["client reap signal", "daemon terminate"],
            "the daemon must not be torn down until the client has detached"
        )
    }

    /// A tab with no recorded process at all — most tabs a `StubProvider` creates — must still
    /// terminate its daemon on close. Nothing about that decision depends on there having been
    /// a client shell for `reapSession` to reap.
    func testCloseSessionTerminatesTheDaemonEvenWithNoRecordedClientProcess() {
        let control = RecordingDaemonControl()
        let store = SessionStore(provider: StubProvider(), persistence: nil, daemonControl: control)
        let session = store.newSession(in: URL(fileURLWithPath: "/tmp"))

        store.closeSession(session.id)
        drainMainQueue()

        XCTAssertEqual(control.terminatedIDs, [session.id])
    }

    // MARK: - restore() reconciles daemons whose session did not come back

    /// A directory with sockets for three sessions, a snapshot that only restores two of them:
    /// the third's daemon has no session left that could ever reattach to it, and `restore()`
    /// must terminate it — while leaving the two that came back alone.
    func testRestoreTerminatesOnlyTheDaemonsWhoseSessionDidNotComeBack() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DaemonLifecycleTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: tempDir) }

        let runDir = tempDir.appendingPathComponent("run")
        try FileManager.default.createDirectory(at: runDir, withIntermediateDirectories: true)
        let daemon = SessionDaemon(directory: runDir, bundledBinary: nil)

        let a = UUID()
        let b = UUID()
        let c = UUID()
        for id in [a, b, c] {
            XCTAssertTrue(
                FileManager.default.createFile(atPath: daemon.socketPath(for: id), contents: nil)
            )
        }

        let persistence = FakePersistence()
        persistence.stored = SessionSnapshot(
            sessions: [
                .init(id: a, title: "a", workingDirectory: tempDir.path),
                .init(id: b, title: "b", workingDirectory: tempDir.path),
            ],
            selectedSessionID: nil,
            sessionCounter: 2
        )

        let control = RecordingDaemonControl()
        let store = SessionStore(
            provider: StubProvider(), persistence: persistence, preferences: nil,
            daemon: daemon, daemonControl: control
        )

        XCTAssertTrue(store.restore())

        XCTAssertEqual(control.terminatedIDs, [c])
    }

    /// The other half: a session that *did* come back must not have its daemon terminated,
    /// even though `restore()`'s own `insertSession` probes `isLive` (which this file's
    /// `RecordingDaemonControl` always answers `false`) on the very same id.
    func testRestoreDoesNotTerminateDaemonsForSessionsThatCameBack() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DaemonLifecycleTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: tempDir) }

        let runDir = tempDir.appendingPathComponent("run")
        try FileManager.default.createDirectory(at: runDir, withIntermediateDirectories: true)
        let daemon = SessionDaemon(directory: runDir, bundledBinary: nil)

        let a = UUID()
        FileManager.default.createFile(atPath: daemon.socketPath(for: a), contents: nil)

        let persistence = FakePersistence()
        persistence.stored = SessionSnapshot(
            sessions: [.init(id: a, title: "a", workingDirectory: tempDir.path)],
            selectedSessionID: nil,
            sessionCounter: 1
        )

        let control = RecordingDaemonControl()
        let store = SessionStore(
            provider: StubProvider(), persistence: persistence, preferences: nil,
            daemon: daemon, daemonControl: control
        )

        XCTAssertTrue(store.restore())

        XCTAssertTrue(control.terminatedIDs.isEmpty)
    }

    // MARK: - quit never terminates a daemon

    /// The other bookend: `reapAllForQuit` must reap every live client shell — proven
    /// elsewhere, in `QuitReapTests` — while never once calling `daemonControl.terminate`.
    /// Daemons persisting across quit is the entire point of this feature.
    func testReapAllForQuitNeverTerminatesADaemon() async {
        let inspector = FakeInspector(living: [601, 602])
        let signals = SpySignals()
        signals.onSend = { pid in inspector.living.remove(pid) }
        let control = RecordingDaemonControl()
        let store = SessionStore(
            provider: StubProvider(),
            persistence: nil,
            reaper: SessionReaper(
                inspector: inspector, signals: signals, sleeper: InstantSleeper()
            ),
            daemonControl: control
        )
        store.processInspector = inspector
        let a = store.newSession(in: URL(fileURLWithPath: "/tmp"))
        let b = store.newSession(in: URL(fileURLWithPath: "/tmp"))
        store.processRegistry.restore([
            a.id: SessionProcess(identity: .init(pid: 601, procStart: 100)),
            b.id: SessionProcess(identity: .init(pid: 602, procStart: 100)),
        ])

        await store.reapAllForQuit(budget: 5)

        XCTAssertTrue(
            control.terminatedIDs.isEmpty,
            "quit must leave every daemon running for the next launch to reattach to"
        )
    }

    // MARK: - SessionDaemon.liveSessionIDs() parsing

    /// Given a directory holding two real sockets, one socket's `.pid` sidecar, and the
    /// `fd-abduco` symlink itself, only the two sockets' ids come back — everything else in
    /// the directory is silently skipped, not mistaken for a session.
    func testLiveSessionIDsParsesSocketFilenamesAndSkipsEverythingElse() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionDaemonLiveIDs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: tempDir) }

        let daemon = SessionDaemon(directory: tempDir, bundledBinary: nil)
        let a = UUID()
        let b = UUID()
        FileManager.default.createFile(atPath: daemon.socketPath(for: a), contents: nil)
        FileManager.default.createFile(atPath: daemon.socketPath(for: b), contents: nil)
        // The `.pid` sidecar for `a` — must not be mistaken for a third session.
        FileManager.default.createFile(atPath: daemon.pidfilePath(for: a), contents: nil)
        // The binary symlink every `resolvedBinaryPath()` call leaves behind.
        try FileManager.default.createSymbolicLink(
            atPath: tempDir.appendingPathComponent("fd-abduco").path,
            withDestinationPath: "/bin/sh"
        )

        XCTAssertEqual(Set(daemon.liveSessionIDs()), [a, b])
    }

    /// A directory that does not exist at all must answer "nothing", not throw or crash — the
    /// state before `ensureDirectory()` has ever run.
    func testLiveSessionIDsIsEmptyForANonexistentDirectory() {
        let daemon = SessionDaemon(
            directory: FileManager.default.temporaryDirectory
                .appendingPathComponent("SessionDaemonLiveIDs-missing-\(UUID().uuidString)"),
            bundledBinary: nil
        )

        XCTAssertEqual(daemon.liveSessionIDs(), [])
    }
}
