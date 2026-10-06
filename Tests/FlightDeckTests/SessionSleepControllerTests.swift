import XCTest
@testable import FlightDeck

@MainActor
final class SessionSleepControllerTests: XCTestCase {
    final class DaemonSpy: DaemonControlling {
        var stopped: [UUID] = []; var conted: [UUID] = []
        var onCont: (() -> Void)?
        func isLive(_ id: UUID) -> Bool { true }
        func isLive(socketPath: String) -> Bool { true }
        func daemonPID(_ id: UUID) -> pid_t? { 111 }
        func daemonPID(socketPath: String) -> pid_t? { 111 }
        func terminate(_ id: UUID) {}
        func terminate(socketPath: String) {}
        func peerPID(socketPath: String) -> pid_t? { nil }
        func terminate(pid: pid_t, socketPath: String) {}
        func stop(_ id: UUID) { stopped.append(id) }
        func cont(_ id: UUID) { conted.append(id); onCont?() }
    }
    struct FixedInspector: ProcessInspecting {
        var result: [ProcessIdentity] = []
        func children(of ppid: pid_t) -> Set<pid_t> { [] }
        func descendants(of pid: pid_t) -> [ProcessIdentity] { result }
        func startTime(of pid: pid_t) -> UInt64? { nil }
        func isAlive(_ identity: ProcessIdentity) -> Bool { false }
        func pgid(of pid: pid_t) -> pid_t? { nil }
    }
    struct FixedResolver: AgentGroupResolving {
        let pgid: pid_t?
        func agentProcessGroup(daemonPID: pid_t) -> pid_t? { pgid }
    }

    func testSleepsIdleUnfocusedSession() {
        let id = UUID(); let daemon = DaemonSpy(); var torn: [UUID] = []
        let ctrl = SessionSleepController(
            policy: SleepPolicy(idleThreshold: 0),      // eligible on the FIRST tick — see below
            daemonControl: daemon, inspector: FixedInspector(result: []),
            resolver: FixedResolver(pgid: 222),
            inputs: SleepInputs(candidates: { [id] }, activity: { _ in .idle },
                                selectedID: { nil }, reportsBackgroundWork: { _ in false },
                                daemonPID: { _ in 111 }),
            tearDownSurface: { torn.append($0) }, now: { Date() })
        // idleThreshold 0: idleSince is set to the same `now` this tick evaluates against, so
        // 0 >= 0 is already satisfied and this FIRST tick sleeps. The second is a no-op — `id`
        // is already in `asleep`, so the loop skips it.
        ctrl.tick()
        ctrl.tick()
        XCTAssertTrue(ctrl.asleep.contains(id))
        XCTAssertEqual(daemon.stopped, [id])
        XCTAssertEqual(torn, [id])
    }

    func testDoesNotSleepBusy() {
        let id = UUID(); let daemon = DaemonSpy()
        let ctrl = SessionSleepController(
            policy: SleepPolicy(idleThreshold: 0), daemonControl: daemon,
            inspector: FixedInspector(result: []), resolver: FixedResolver(pgid: 222),
            inputs: SleepInputs(candidates: { [id] }, activity: { _ in .busy },
                                selectedID: { nil }, reportsBackgroundWork: { _ in false },
                                daemonPID: { _ in 111 }),
            tearDownSurface: { _ in }, now: { Date() })
        ctrl.tick(); ctrl.tick()
        XCTAssertFalse(ctrl.asleep.contains(id)); XCTAssertTrue(daemon.stopped.isEmpty)
    }

    func testLiveDescendantsBlockSleep() {
        let id = UUID(); let daemon = DaemonSpy()
        let ctrl = SessionSleepController(
            policy: SleepPolicy(idleThreshold: 0), daemonControl: daemon,
            inspector: FixedInspector(result: [ProcessIdentity(pid: 900, procStart: 1)]),
            resolver: FixedResolver(pgid: 222),
            inputs: SleepInputs(candidates: { [id] }, activity: { _ in .idle },
                                selectedID: { nil }, reportsBackgroundWork: { _ in false },
                                daemonPID: { _ in 111 }),
            tearDownSurface: { _ in }, now: { Date() })
        ctrl.tick(); ctrl.tick()
        XCTAssertTrue(daemon.stopped.isEmpty)
    }

    func testBusyResetsIdleClock() {
        let id = UUID(); var act: SessionActivity = .idle; let daemon = DaemonSpy()
        let ctrl = SessionSleepController(
            policy: SleepPolicy(idleThreshold: 10), daemonControl: daemon,
            inspector: FixedInspector(result: []), resolver: FixedResolver(pgid: 222),
            inputs: SleepInputs(candidates: { [id] }, activity: { _ in act },
                                selectedID: { nil }, reportsBackgroundWork: { _ in false },
                                daemonPID: { _ in 111 }),
            tearDownSurface: { _ in }, now: { Date() })
        ctrl.tick()               // idle → clock starts
        act = .busy; ctrl.tick()  // clears clock
        act = .idle; ctrl.tick()  // restarts; < 10s
        XCTAssertFalse(ctrl.asleep.contains(id))
    }

    func testWakeConts() {
        let id = UUID(); let daemon = DaemonSpy()
        let ctrl = SessionSleepController(
            policy: SleepPolicy(idleThreshold: 0), daemonControl: daemon,
            inspector: FixedInspector(result: []), resolver: FixedResolver(pgid: 222),
            inputs: SleepInputs(candidates: { [id] }, activity: { _ in .idle },
                                selectedID: { nil }, reportsBackgroundWork: { _ in false },
                                daemonPID: { _ in 111 }),
            tearDownSurface: { _ in }, now: { Date() })
        ctrl.tick(); ctrl.tick()          // threshold 0: the first tick already sleeps; the second is a no-op
        ctrl.wake(id)
        XCTAssertEqual(daemon.conted, [id]); XCTAssertFalse(ctrl.asleep.contains(id))
    }

    func testDisabledSuppressesSleep() {
        let id = UUID(); let daemon = DaemonSpy()
        let ctrl = SessionSleepController(
            policy: SleepPolicy(idleThreshold: 0), daemonControl: daemon,
            inspector: FixedInspector(result: []), resolver: FixedResolver(pgid: 222),
            inputs: SleepInputs(candidates: { [id] }, activity: { _ in .idle }, selectedID: { nil },
                                reportsBackgroundWork: { _ in false }, daemonPID: { _ in 111 }),
            tearDownSurface: { _ in }, rebuildSurface: { _ in },
            sleepEnabled: { false },       // Off
            now: { Date() })
        ctrl.tick(); ctrl.tick()
        XCTAssertFalse(ctrl.asleep.contains(id)); XCTAssertTrue(daemon.stopped.isEmpty)
    }

    func testWakeContsThenRebuilds() {
        let id = UUID(); let daemon = DaemonSpy(); var order: [String] = []
        daemon.onCont = { order.append("cont") }
        let ctrl = SessionSleepController(
            policy: SleepPolicy(idleThreshold: 0), daemonControl: daemon,
            inspector: FixedInspector(result: []), resolver: FixedResolver(pgid: 222),
            inputs: SleepInputs(candidates: { [id] }, activity: { _ in .idle }, selectedID: { nil },
                                reportsBackgroundWork: { _ in false }, daemonPID: { _ in 111 }),
            tearDownSurface: { _ in }, rebuildSurface: { _ in order.append("rebuild") }, now: { Date() })
        ctrl.tick(); ctrl.tick()          // threshold 0: the first tick already sleeps; the second is a no-op
        ctrl.wake(id)
        XCTAssertEqual(order, ["cont", "rebuild"])
        XCTAssertFalse(ctrl.asleep.contains(id))
    }

    func testWakeWhenNotAsleepIsANoOp() {
        let id = UUID(); let daemon = DaemonSpy(); var rebuilt: [UUID] = []
        let ctrl = SessionSleepController(
            policy: SleepPolicy(idleThreshold: 0), daemonControl: daemon,
            inspector: FixedInspector(result: []), resolver: FixedResolver(pgid: 222),
            inputs: SleepInputs(candidates: { [id] }, activity: { _ in .idle }, selectedID: { nil },
                                reportsBackgroundWork: { _ in false }, daemonPID: { _ in 111 }),
            tearDownSurface: { _ in }, rebuildSurface: { rebuilt.append($0) }, now: { Date() })
        ctrl.wake(id)   // never ticked, never slept
        XCTAssertTrue(daemon.conted.isEmpty)
        XCTAssertTrue(rebuilt.isEmpty)
        XCTAssertTrue(ctrl.asleep.isEmpty)
    }

    func testNilActivityClearsIdleClockAndNeverSleeps() {
        let id = UUID(); let daemon = DaemonSpy()
        let ctrl = SessionSleepController(
            policy: SleepPolicy(idleThreshold: 0), daemonControl: daemon,
            inspector: FixedInspector(result: []), resolver: FixedResolver(pgid: 222),
            inputs: SleepInputs(candidates: { [id] }, activity: { _ in nil },   // no live agent
                                selectedID: { nil }, reportsBackgroundWork: { _ in false },
                                daemonPID: { _ in 111 }),
            tearDownSurface: { _ in }, now: { Date() })
        ctrl.tick(); ctrl.tick(); ctrl.tick()
        XCTAssertFalse(ctrl.asleep.contains(id))
        XCTAssertTrue(daemon.stopped.isEmpty)
    }

    // MARK: Skip-work — the per-tick process-tree walk (2026-10-05)

    /// Counts the expensive lookups the tick performs.
    final class Counting {
        var daemonPID = 0; var resolve = 0
    }
    struct CountingResolver: AgentGroupResolving {
        let counts: Counting
        func agentProcessGroup(daemonPID: pid_t) -> pid_t? { counts.resolve += 1; return 222 }
    }

    /// A tab that cannot sleep for a cheap reason — selected, busy, not idle long enough —
    /// must not pay for the pidfile read and the process-tree walk that could only make it
    /// *more* ineligible. Measured live: those two were ~5% of a core on the main thread with
    /// 78 tabs, every 500ms, almost all of it for tabs that were never going to sleep.
    func testACheaplyIneligibleTabReadsNoPidfileAndWalksNoTree() {
        let selected = UUID(), fresh = UUID(), busy = UUID()
        let counts = Counting()
        let ctrl = SessionSleepController(
            policy: SleepPolicy(idleThreshold: 600), daemonControl: DaemonSpy(),
            inspector: FixedInspector(result: []), resolver: CountingResolver(counts: counts),
            inputs: SleepInputs(
                candidates: { [selected, fresh, busy] },
                activity: { $0 == busy ? .busy : .idle },
                selectedID: { selected }, reportsBackgroundWork: { _ in false },
                daemonPID: { _ in counts.daemonPID += 1; return 111 }),
            tearDownSurface: { _ in }, now: { Date() })
        for _ in 0..<5 { ctrl.tick() }
        XCTAssertEqual(counts.daemonPID, 0)
        XCTAssertEqual(counts.resolve, 0)
        XCTAssertTrue(ctrl.asleep.isEmpty)
    }

    /// A tab that passes every cheap gate but stays ineligible on an expensive one — an agent
    /// with live children, the ordinary claude-with-MCP-servers case — is re-checked at most
    /// once per `evaluationInterval`, not on every tick. The idle clock itself is still kept
    /// every tick, so a busy blip between evaluations still resets it.
    func testTheExpensiveCheckIsThrottledButTheIdleClockIsNot() {
        let id = UUID(); let counts = Counting(); let daemon = DaemonSpy()
        var clock = Date(timeIntervalSince1970: 1_000)
        var activity: SessionActivity = .idle
        let ctrl = SessionSleepController(
            policy: SleepPolicy(idleThreshold: 10), daemonControl: daemon,
            // A live child (an MCP server): ineligible on the expensive gate, every time.
            inspector: FixedInspector(result: [ProcessIdentity(pid: 900, procStart: 1)]),
            resolver: CountingResolver(counts: counts),
            inputs: SleepInputs(
                candidates: { [id] }, activity: { _ in activity },
                selectedID: { nil }, reportsBackgroundWork: { _ in false },
                daemonPID: { _ in counts.daemonPID += 1; return 111 }),
            tearDownSurface: { _ in }, evaluationInterval: 5, now: { clock })
        ctrl.tick()                                   // t=0: idle clock starts
        clock += 11; ctrl.tick()                      // t=11: eligible on cheap gates → one lookup
        XCTAssertEqual(counts.resolve, 1)
        clock += 0.5; ctrl.tick()                     // t=11.5: inside the interval → no lookup
        clock += 0.5; ctrl.tick()
        XCTAssertEqual(counts.resolve, 1, "throttled to one walk per evaluationInterval")

        // A busy blip between evaluations still resets the idle clock.
        activity = .busy; clock += 0.5; ctrl.tick()
        activity = .idle; clock += 0.5; ctrl.tick()
        clock += 5; ctrl.tick()                       // interval elapsed, but idle only 5.5s
        XCTAssertEqual(counts.resolve, 1, "not idle long enough again: the walk is not even asked")
        XCTAssertTrue(daemon.stopped.isEmpty)
    }
}
