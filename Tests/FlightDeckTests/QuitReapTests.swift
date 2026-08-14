// Tests/FlightDeckTests/QuitReapTests.swift
import XCTest
@testable import FlightDeck

private final class StubProvider: SurfaceProvider {
    func makeSurface(_ config: Ghostty.SurfaceConfiguration) -> Ghostty.SurfaceView? { nil }
    func tick() {}
}

private final class FakeInspector: ProcessInspecting, @unchecked Sendable {
    var living: Set<pid_t>
    init(living: Set<pid_t>) { self.living = living }
    func children(of ppid: pid_t) -> Set<pid_t> { [] }
    func descendants(of pid: pid_t) -> [ProcessIdentity] { [] }
    func startTime(of pid: pid_t) -> UInt64? { living.contains(pid) ? 100 : nil }
    func isAlive(_ identity: ProcessIdentity) -> Bool {
        living.contains(identity.pid) && identity.procStart == 100
    }
    func pgid(of pid: pid_t) -> pid_t? { living.contains(pid) ? pid : nil }
}

private final class SpySignals: SignalSending, @unchecked Sendable {
    var targets: [pid_t] = []
    var onSend: ((pid_t) -> Void)?
    func send(_ signal: Int32, toGroup pgid: pid_t) -> Bool {
        targets.append(pgid); onSend?(pgid); return true
    }
    func send(_ signal: Int32, toProcess pid: pid_t) -> Bool {
        targets.append(pid); onSend?(pid); return true
    }
    func ownProcessGroup() -> pid_t { 999 }
}

private struct InstantSleeper: ReaperSleeping {
    func sleep(seconds: Double) async {}
}

@MainActor
final class QuitReapTests: XCTestCase {
    func testQuitReapsEveryLiveSession() async {
        let inspector = FakeInspector(living: [601, 602])
        let signals = SpySignals()
        signals.onSend = { pid in inspector.living.remove(pid) }
        let store = SessionStore(
            provider: StubProvider(),
            persistence: nil,
            reaper: SessionReaper(
                inspector: inspector, signals: signals, sleeper: InstantSleeper()
            )
        )
        let a = store.newSession(in: URL(fileURLWithPath: "/tmp"))
        let b = store.newSession(in: URL(fileURLWithPath: "/tmp"))
        store.processRegistry.restore([
            a.id: SessionProcess(identity: .init(pid: 601, procStart: 100), pgid: 601),
            b.id: SessionProcess(identity: .init(pid: 602, procStart: 100), pgid: 602),
        ])

        await store.reapAllForQuit(budget: 5)

        XCTAssertEqual(Set(signals.targets), [601, 602])
    }

    /// Quit must return even when nothing can be killed — the budget is the guarantee.
    func testQuitReturnsEvenWhenNothingDies() async {
        let store = SessionStore(
            provider: StubProvider(),
            persistence: nil,
            reaper: SessionReaper(
                inspector: FakeInspector(living: [601]),
                signals: SpySignals(),
                sleeper: InstantSleeper()
            )
        )
        let a = store.newSession(in: URL(fileURLWithPath: "/tmp"))
        store.processRegistry.restore([
            a.id: SessionProcess(identity: .init(pid: 601, procStart: 100), pgid: 601)
        ])

        await store.reapAllForQuit(budget: 1)

        XCTAssertTrue(true, "returned rather than hanging")
    }

    func testQuitWithNoSessionsIsANoOp() async {
        let store = SessionStore(provider: StubProvider(), persistence: nil)
        await store.reapAllForQuit(budget: 1)
        XCTAssertTrue(true)
    }

    /// The regression this ruling exists to prevent. `closeSession` no longer forgets a
    /// session's process record synchronously — see `reapSession`'s doc comment — so a tab
    /// closed moments before quit is still in `processRegistry.all` for the whole reap window,
    /// and `reapAllForQuit` must still find and reap it rather than skip it as already gone.
    func testQuitStillReapsASessionWhoseTabCloseReapIsInFlight() async {
        let inspector = FakeInspector(living: [601])
        let signals = SpySignals()
        signals.onSend = { pid in inspector.living.remove(pid) }
        let store = SessionStore(
            provider: StubProvider(),
            persistence: nil,
            reaper: SessionReaper(
                inspector: inspector, signals: signals, sleeper: InstantSleeper()
            )
        )
        let a = store.newSession(in: URL(fileURLWithPath: "/tmp"))
        store.processRegistry.restore([
            a.id: SessionProcess(identity: .init(pid: 601, procStart: 100), pgid: 601)
        ])

        store.closeSession(a.id)
        // Deliberately not draining the run loop: `closeSession`'s own reap `Task` has been
        // scheduled but cannot run until this synchronous test method suspends, so the record
        // it will eventually forget is still exactly where quit needs to find it.
        XCTAssertNotNil(
            store.processRegistry.process(for: a.id),
            "still recorded mid-window, not forgotten synchronously by closeSession"
        )

        await store.reapAllForQuit(budget: 5)

        XCTAssertTrue(signals.targets.contains(601), "quit reaped the in-flight-closed session too")
    }
}
