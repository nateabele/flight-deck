import XCTest
@testable import FlightDeck

@MainActor
final class SessionSleepControllerTests: XCTestCase {
    final class DaemonSpy: DaemonControlling {
        var stopped: [UUID] = []; var conted: [UUID] = []
        var onCont: (() -> Void)?
        func isLive(_ id: UUID) -> Bool { true }
        func daemonPID(_ id: UUID) -> pid_t? { 111 }
        func terminate(_ id: UUID) {}
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
            policy: SleepPolicy(idleThreshold: 0),      // threshold 0 => eligible on 2nd tick
            daemonControl: daemon, inspector: FixedInspector(result: []),
            resolver: FixedResolver(pgid: 222),
            inputs: SleepInputs(candidates: { [id] }, activity: { _ in .idle },
                                selectedID: { nil }, reportsBackgroundWork: { _ in false },
                                daemonPID: { _ in 111 }),
            tearDownSurface: { torn.append($0) }, now: { Date() })
        ctrl.tick()   // sets idleSince
        ctrl.tick()   // threshold 0 satisfied → sleeps
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
        ctrl.tick(); ctrl.tick()          // sleeps
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
        ctrl.tick(); ctrl.tick()          // sleeps
        ctrl.wake(id)
        XCTAssertEqual(order, ["cont", "rebuild"])
        XCTAssertFalse(ctrl.asleep.contains(id))
    }
}
