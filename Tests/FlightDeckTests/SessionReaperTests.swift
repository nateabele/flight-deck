// Tests/FlightDeckTests/SessionReaperTests.swift
import XCTest
@testable import FlightDeck

/// A scripted process table. Tests kill a pid by mutating `living` from a `SpySignals.onSend`
/// or `SpySleeper.onSleep` hook, which is how the ladder's short-circuiting gets exercised.
private final class FakeInspector: ProcessInspecting, @unchecked Sendable {
    var living: Set<pid_t>
    var tree: [pid_t: [ProcessIdentity]]
    /// Descendants are only visible while the parent is alive — this mirrors reality, where
    /// children are reparented to launchd the moment their parent dies.
    init(living: Set<pid_t>, tree: [pid_t: [ProcessIdentity]] = [:]) {
        self.living = living
        self.tree = tree
    }

    func children(of ppid: pid_t) -> Set<pid_t> { Set((tree[ppid] ?? []).map(\.pid)) }

    func descendants(of pid: pid_t) -> [ProcessIdentity] {
        guard living.contains(pid) else { return [] }
        return tree[pid] ?? []
    }

    func startTime(of pid: pid_t) -> UInt64? { living.contains(pid) ? 100 : nil }
    func isAlive(_ identity: ProcessIdentity) -> Bool {
        living.contains(identity.pid) && identity.procStart == 100
    }
}

private final class SpySignals: SignalSending, @unchecked Sendable {
    struct Sent: Equatable { let signal: Int32; let target: pid_t; let isGroup: Bool }
    var sent: [Sent] = []
    var ownGroup: pid_t = 999
    /// Called after each send so a test can script "this signal kills it".
    var onSend: ((Sent) -> Void)?

    func send(_ signal: Int32, toGroup pgid: pid_t) -> Bool {
        let s = Sent(signal: signal, target: pgid, isGroup: true)
        sent.append(s); onSend?(s); return true
    }
    func send(_ signal: Int32, toProcess pid: pid_t) -> Bool {
        let s = Sent(signal: signal, target: pid, isGroup: false)
        sent.append(s); onSend?(s); return true
    }
    func ownProcessGroup() -> pid_t { ownGroup }
}

/// Records every requested sleep instead of actually waiting, so a test can assert the
/// ladder's deadline machinery directly rather than only its end result: that a rung polls
/// its full budget before escalating, and that a target dying (or a cancellation landing)
/// mid-rung stops further polling immediately instead of spinning through the rest.
private final class SpySleeper: ReaperSleeping, @unchecked Sendable {
    var seconds: [Double] = []
    /// Called after each recorded sleep, so a test can kill a target — or cancel the
    /// in-flight task — at a specific poll.
    var onSleep: (() -> Void)?

    func sleep(seconds: Double) async {
        self.seconds.append(seconds)
        onSleep?()
    }
}

final class SessionReaperTests: XCTestCase {
    private let shell = ProcessIdentity(pid: 4242, procStart: 100)

    func testAShellThatDiesOnSIGHUPIsSignalledOnce() async {
        let inspector = FakeInspector(living: [4242])
        let signals = SpySignals()
        signals.onSend = { _ in inspector.living.remove(4242) }
        let reaper = SessionReaper(inspector: inspector, signals: signals, sleeper: SpySleeper())

        let outcome = await reaper.reap(shell: shell, pgid: 4242)

        XCTAssertEqual(outcome, .clean)
        XCTAssertEqual(signals.sent, [.init(signal: SIGHUP, target: 4242, isGroup: true)])
    }

    func testAStubbornShellEscalatesAllTheWayToSIGKILL() async {
        let inspector = FakeInspector(living: [4242])
        let signals = SpySignals()
        signals.onSend = { sent in if sent.signal == SIGKILL { inspector.living.remove(4242) } }
        let reaper = SessionReaper(inspector: inspector, signals: signals, sleeper: SpySleeper())

        let outcome = await reaper.reap(shell: shell, pgid: 4242)

        XCTAssertEqual(outcome, .clean)
        XCTAssertEqual(signals.sent.map(\.signal), [SIGHUP, SIGTERM, SIGKILL])
    }

    func testAnUnkillableShellIsReportedAsASurvivor() async {
        let inspector = FakeInspector(living: [4242])
        let sleeper = SpySleeper()
        let reaper = SessionReaper(
            inspector: inspector, signals: SpySignals(), sleeper: sleeper
        )

        let outcome = await reaper.reap(shell: shell, pgid: 4242)

        XCTAssertEqual(outcome, .survivors([shell]))
        // Every rung polls its full budget before escalating to the next one: 40 + 40 + 20
        // polls of 0.05 s each, 5 s total across the whole ladder. A sleeper that recorded
        // nothing (cancellation collapse) or far more than this (serial escapee ladders)
        // would both fail this assertion.
        XCTAssertEqual(sleeper.seconds.count, 100, "expected 40 + 40 + 20 polls across the ladder")
        XCTAssertEqual(sleeper.seconds.reduce(0, +), 5.0, accuracy: 0.0001)
    }

    /// A target that dies partway through a rung's budget stops the ladder immediately:
    /// no further polling for the rest of that rung, and no signal for the next one.
    func testATargetDyingMidRungStopsFurtherPollingAndSignals() async {
        let inspector = FakeInspector(living: [4242])
        let signals = SpySignals()
        let sleeper = SpySleeper()
        var pollCount = 0
        sleeper.onSleep = {
            pollCount += 1
            if pollCount == 3 { inspector.living.remove(4242) }
        }
        let reaper = SessionReaper(inspector: inspector, signals: signals, sleeper: sleeper)

        let outcome = await reaper.reap(shell: shell, pgid: 4242)

        XCTAssertEqual(outcome, .clean)
        XCTAssertEqual(signals.sent.map(\.signal), [SIGHUP], "died before SIGTERM was ever sent")
        XCTAssertEqual(
            sleeper.seconds.count, 3,
            "must stop polling the instant the target dies, not spin out the rest of the budget"
        )
    }

    /// A cancelled reap does not fast-forward to SIGKILL. `RealSleeper.sleep` swallows
    /// `CancellationError` via `try?` and returns immediately once cancelled, so without an
    /// explicit `Task.isCancelled` check the poll loop would spin through its remaining
    /// budget in microseconds and fire every rung back to back the moment the caller gives up
    /// — turning a graceful shutdown into an instant kill.
    func testCancellationStopsTheLadderInsteadOfEscalating() async {
        let inspector = FakeInspector(living: [4242])
        let signals = SpySignals()
        let sleeper = SpySleeper()
        sleeper.onSleep = {
            withUnsafeCurrentTask { $0?.cancel() }
        }
        let reaper = SessionReaper(inspector: inspector, signals: signals, sleeper: sleeper)

        let outcome = await reaper.reap(shell: shell, pgid: 4242)

        XCTAssertEqual(
            signals.sent.map(\.signal), [SIGHUP],
            "cancellation must not fast-forward through SIGTERM and SIGKILL"
        )
        XCTAssertEqual(
            sleeper.seconds.count, 1,
            "must stop on the first post-cancellation check, not spin the rest of the budget"
        )
        XCTAssertEqual(
            outcome, .survivors([shell]),
            "a cancelled reap cannot claim success for a shell it never confirmed dead"
        )
    }

    /// The ordering guarantee from the spec: the tree is captured while the shell is alive,
    /// because a tree walked after the kill is always empty.
    func testAnEscapeeIsLadderedEvenThoughTheTreeVanishesWithTheShell() async {
        let escapee = ProcessIdentity(pid: 5555, procStart: 100)
        let inspector = FakeInspector(living: [4242, 5555], tree: [4242: [escapee]])
        let signals = SpySignals()
        signals.onSend = { sent in
            // The group kill takes the shell but not the escapee, which left the group.
            if sent.isGroup { inspector.living.remove(4242) }
            if sent.target == 5555, sent.signal == SIGKILL { inspector.living.remove(5555) }
        }
        let reaper = SessionReaper(inspector: inspector, signals: signals, sleeper: SpySleeper())

        let outcome = await reaper.reap(shell: shell, pgid: 4242)

        XCTAssertEqual(outcome, .clean)
        let perPid = signals.sent.filter { !$0.isGroup }
        XCTAssertEqual(perPid.map(\.target), [5555, 5555, 5555])
        XCTAssertEqual(perPid.map(\.signal), [SIGHUP, SIGTERM, SIGKILL])
    }

    /// Without this rail, reaping a process that shares our group kills us.
    func testNeverKillpgsItsOwnProcessGroup() async {
        let inspector = FakeInspector(living: [4242])
        let signals = SpySignals()
        signals.ownGroup = 777
        signals.onSend = { _ in inspector.living.remove(4242) }
        let reaper = SessionReaper(inspector: inspector, signals: signals, sleeper: SpySleeper())

        _ = await reaper.reap(shell: shell, pgid: 777)

        XCTAssertTrue(signals.sent.allSatisfy { !$0.isGroup }, "must not signal its own group")
        XCTAssertEqual(signals.sent.first?.target, 4242, "falls back to per-pid")
    }

    /// A pid that died and was recycled must not be signalled: same pid, different start time.
    func testDoesNotSignalARecycledPid() async {
        let inspector = FakeInspector(living: [4242])   // start time 100
        let stale = ProcessIdentity(pid: 4242, procStart: 55)
        let signals = SpySignals()
        let reaper = SessionReaper(inspector: inspector, signals: signals, sleeper: SpySleeper())

        let outcome = await reaper.reap(shell: stale, pgid: 4242)

        XCTAssertEqual(outcome, .clean)
        XCTAssertTrue(signals.sent.isEmpty)
    }
}
