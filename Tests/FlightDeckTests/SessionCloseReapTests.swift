// Tests/FlightDeckTests/SessionCloseReapTests.swift
import XCTest
@testable import FlightDeck

private final class StubProvider: SurfaceProvider {
    func makeSurface(_ config: Ghostty.SurfaceConfiguration) -> Ghostty.SurfaceView? { nil }
    func tick() {}
}

private final class SpyReporter: ReapReporting, @unchecked Sendable {
    var reported: [ReapOutcome] = []
    var contexts: [String] = []
    var sweeps: [Int] = []
    func report(_ outcome: ReapOutcome, context: String) {
        reported.append(outcome)
        contexts.append(context)
    }
    func reportSweep(cleaned: Int) { sweeps.append(cleaned) }
}

/// A minimal scripted process table for this file's own reaper injection. Deliberately
/// simpler than `SessionReaperTests`' `FakeInspector` — this file never exercises the
/// ladder's escalation machinery, only whether `closeSession` invokes `reap` at all.
private final class FakeInspector: ProcessInspecting, @unchecked Sendable {
    var living: Set<pid_t>
    init(living: Set<pid_t> = []) { self.living = living }
    func children(of ppid: pid_t) -> Set<pid_t> { [] }
    func descendants(of pid: pid_t) -> [ProcessIdentity] { [] }
    func startTime(of pid: pid_t) -> UInt64? { living.contains(pid) ? 100 : nil }
    func isAlive(_ identity: ProcessIdentity) -> Bool {
        living.contains(identity.pid) && identity.procStart == 100
    }
    /// `reapSession` re-derives the group here rather than trusting anything on the record —
    /// `SessionProcess` carries no `pgid` at all. Reporting "could not establish a group" is
    /// the honest answer for a scripted table and sends the ladder down its per-pid path.
    func pgid(of pid: pid_t) -> pid_t? { nil }
}

/// Records signals instead of touching a real process. Nothing reachable from a test may
/// construct `PosixSignals` — see `SurfaceProcessRegistryTests` and `SessionReaperTests` for
/// the same rule enforced the same way.
private final class SpySignals: SignalSending, @unchecked Sendable {
    /// Called after each send so a test can script "this signal kills it", mirroring
    /// `SessionReaperTests`' `SpySignals`.
    var onSend: (() -> Void)?
    func send(_ signal: Int32, toGroup pgid: pid_t) -> Bool { onSend?(); return true }
    func send(_ signal: Int32, toProcess pid: pid_t) -> Bool { onSend?(); return true }
    func ownProcessGroup() -> pid_t { 999 }
}

/// Sleeps not at all, so a ladder that does run finishes instantly instead of taking up to
/// 5 s per rung.
private final class InstantSleeper: ReaperSleeping, @unchecked Sendable {
    func sleep(seconds: Double) async {}
}

@MainActor
final class SessionCloseReapTests: XCTestCase {
    /// Let the detached reap `Task` created by `closeSession` run to completion. Same
    /// technique as `SurfaceLifecycleTests.drainMainQueue()`: pumping the run loop lets the
    /// main-actor `Task` make progress and return from its `await` into the reaper actor.
    private func drainMainQueue() {
        let exp = expectation(description: "drain")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)
    }

    /// Every test gets a reaper built from fakes. Nothing here may fire the real
    /// `SessionReaper` default (`ProcessTree()` + `PosixSignals()` + `RealSleeper()`) — that
    /// reaches real `killpg`/`kill` calls, and `reap`'s `isAlive` guard being the only thing
    /// standing between a scripted pid like 31337 and a real signal is not a safety margin a
    /// unit test should depend on.
    private func store(
        inspector: ProcessInspecting = FakeInspector(),
        signals: SignalSending = SpySignals()
    ) -> SessionStore {
        let s = SessionStore(
            provider: StubProvider(),
            persistence: nil,
            reaper: SessionReaper(inspector: inspector, signals: signals, sleeper: InstantSleeper())
        )
        // The same scripted table `reapSession` re-derives the group from, so no test in this
        // file reaches the real `ProcessTree` for a `getpgid` on a made-up pid.
        s.processInspector = inspector
        return s
    }

    /// A tab with no recorded process must still close cleanly — this is every tab created
    /// by a stub provider, and every tab whose pid diff came back ambiguous.
    func testClosingATabWithNoRecordedProcessStillCloses() {
        let s = store()
        let session = s.newSession(in: URL(fileURLWithPath: "/tmp"))

        s.closeSession(session.id)

        XCTAssertTrue(s.repos.flatMap(\.sessions).isEmpty)
    }

    /// The record has to survive `closeSession` itself and only disappear once the reap has
    /// actually run: forgetting it synchronously (the old behavior) opened a window where the
    /// process was recorded nowhere at all — gone from the live registry and, since
    /// `closeSession`'s own `persist()` had already fired, absent from the on-disk snapshot
    /// too. See `reapSession`'s doc comment.
    func testClosingForgetsTheProcessRecordOnceTheReapDrains() {
        let s = store()
        let session = s.newSession(in: URL(fileURLWithPath: "/tmp"))
        s.processRegistry.restore([
            session.id: SessionProcess(
                identity: ProcessIdentity(pid: 31337, procStart: 1)
            )
        ])

        s.closeSession(session.id)
        XCTAssertNotNil(
            s.processRegistry.process(for: session.id),
            "still recorded during the reap window, not forgotten synchronously"
        )
        drainMainQueue()

        XCTAssertNil(s.processRegistry.process(for: session.id))
    }

    /// The row must vanish synchronously; only the invisible surface teardown is deferred.
    func testTheRowDisappearsImmediatelyEvenThoughTheReapIsAsync() {
        let s = store()
        let first = s.newSession(in: URL(fileURLWithPath: "/tmp"))
        let second = s.newSession(in: URL(fileURLWithPath: "/tmp"))

        s.closeSession(first.id)

        XCTAssertEqual(s.repos.flatMap(\.sessions).map(\.id), [second.id])
        XCTAssertEqual(s.selectedSessionID, second.id)
    }

    /// A close notification carrying no surface must be a no-op, not a crash or a stray close.
    ///
    /// This covers the `note.object as? Ghostty.SurfaceView` cast failing, and only that. The
    /// parked-surface interleaving — a late notification that passes the cast and then misses
    /// the `surfaces` lookup one line later — needs a real `Ghostty.SurfaceView`, which cannot
    /// be constructed without a live `ghostty_app_t`, so it is not covered here.
    func testCloseNotificationWithNoSurfaceIsIgnored() {
        let s = store()
        let session = s.newSession(in: URL(fileURLWithPath: "/tmp"))

        NotificationCenter.default.post(
            name: Ghostty.Notification.ghosttyCloseSurface, object: nil
        )

        XCTAssertEqual(s.repos.flatMap(\.sessions).map(\.id), [session.id])
    }

    /// The behavior this task exists to add: closing a tab with a live recorded process
    /// actually runs the reaper and reports the outcome. Nothing before this test proved
    /// `reapSession` was ever invoked from `closeSession`.
    func testClosingATabWithALiveProcessReapsItAndReportsClean() {
        let inspector = FakeInspector(living: [31337])
        let signals = SpySignals()
        // The shell dies on the first signal (SIGHUP) — the overwhelming majority case per
        // `SessionReaper`'s own doc comment — so the ladder stops immediately instead of
        // escalating through SIGTERM/SIGKILL.
        signals.onSend = { [weak inspector] in inspector?.living.remove(31337) }
        let s = store(inspector: inspector, signals: signals)
        let reporter = SpyReporter()
        s.reapReporter = reporter
        let session = s.newSession(in: URL(fileURLWithPath: "/tmp"))
        s.processRegistry.restore([
            session.id: SessionProcess(
                identity: ProcessIdentity(pid: 31337, procStart: 100)
            )
        ])

        s.closeSession(session.id)
        drainMainQueue()

        XCTAssertEqual(reporter.reported, [.clean])
        XCTAssertEqual(reporter.contexts, ["tab close"])
    }
}
