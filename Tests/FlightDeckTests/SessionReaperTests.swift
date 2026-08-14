// Tests/FlightDeckTests/SessionReaperTests.swift
import XCTest
@testable import FlightDeck

/// A scripted process table. `aliveUntilSignal` lets a test say "this pid dies once it has
/// been sent SIGTERM", which is how the ladder's short-circuiting gets exercised.
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

private struct InstantSleeper: ReaperSleeping {
    func sleep(seconds: Double) async {}
}

final class SessionReaperTests: XCTestCase {
    private let shell = ProcessIdentity(pid: 4242, procStart: 100)

    func testAShellThatDiesOnSIGHUPIsSignalledOnce() async {
        let inspector = FakeInspector(living: [4242])
        let signals = SpySignals()
        signals.onSend = { _ in inspector.living.remove(4242) }
        let reaper = SessionReaper(inspector: inspector, signals: signals, sleeper: InstantSleeper())

        let outcome = await reaper.reap(shell: shell, pgid: 4242)

        XCTAssertEqual(outcome, .clean)
        XCTAssertEqual(signals.sent, [.init(signal: SIGHUP, target: 4242, isGroup: true)])
    }

    func testAStubbornShellEscalatesAllTheWayToSIGKILL() async {
        let inspector = FakeInspector(living: [4242])
        let signals = SpySignals()
        signals.onSend = { sent in if sent.signal == SIGKILL { inspector.living.remove(4242) } }
        let reaper = SessionReaper(inspector: inspector, signals: signals, sleeper: InstantSleeper())

        let outcome = await reaper.reap(shell: shell, pgid: 4242)

        XCTAssertEqual(outcome, .clean)
        XCTAssertEqual(signals.sent.map(\.signal), [SIGHUP, SIGTERM, SIGKILL])
    }

    func testAnUnkillableShellIsReportedAsASurvivor() async {
        let inspector = FakeInspector(living: [4242])
        let reaper = SessionReaper(
            inspector: inspector, signals: SpySignals(), sleeper: InstantSleeper()
        )

        let outcome = await reaper.reap(shell: shell, pgid: 4242)

        XCTAssertEqual(outcome, .survivors([shell]))
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
        let reaper = SessionReaper(inspector: inspector, signals: signals, sleeper: InstantSleeper())

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
        let reaper = SessionReaper(inspector: inspector, signals: signals, sleeper: InstantSleeper())

        _ = await reaper.reap(shell: shell, pgid: 777)

        XCTAssertTrue(signals.sent.allSatisfy { !$0.isGroup }, "must not signal its own group")
        XCTAssertEqual(signals.sent.first?.target, 4242, "falls back to per-pid")
    }

    /// A pid that died and was recycled must not be signalled: same pid, different start time.
    func testDoesNotSignalARecycledPid() async {
        let inspector = FakeInspector(living: [4242])   // start time 100
        let stale = ProcessIdentity(pid: 4242, procStart: 55)
        let signals = SpySignals()
        let reaper = SessionReaper(inspector: inspector, signals: signals, sleeper: InstantSleeper())

        let outcome = await reaper.reap(shell: stale, pgid: 4242)

        XCTAssertEqual(outcome, .clean)
        XCTAssertTrue(signals.sent.isEmpty)
    }
}
