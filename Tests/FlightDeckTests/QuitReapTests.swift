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

/// Blocks until the task awaiting it is cancelled, instead of ever returning on its own.
/// `InstantSleeper` finishes a whole ladder before the deadline task could ever win
/// `reapAllForQuit`'s race, so it cannot exercise the budget-expiry branch at all — this
/// sleeper is what makes that branch genuinely run.
private final class HangingSleeper: ReaperSleeping, @unchecked Sendable {
    /// One instance per `sleep` call (not shared across calls), guarded by a lock so
    /// "cancel arrives before the continuation is registered" and "registered before
    /// cancel" both resume exactly once with no lost wakeup.
    private final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Never>?
        private var cancelled = false

        func register(_ continuation: CheckedContinuation<Void, Never>) {
            lock.lock()
            if cancelled {
                lock.unlock()
                continuation.resume()
                return
            }
            self.continuation = continuation
            lock.unlock()
        }

        func cancel() {
            lock.lock()
            let pending = continuation
            continuation = nil
            cancelled = true
            lock.unlock()
            pending?.resume()
        }
    }

    func sleep(seconds: Double) async {
        let state = State()
        await withTaskCancellationHandler {
            await withCheckedContinuation { state.register($0) }
        } onCancel: {
            state.cancel()
        }
    }
}

/// Captures the pid most recently signalled, from `SpySignals.onSend`, so a sleeper can
/// decide whether *this* poll belongs to the target it should stall.
private final class SignalTracker: @unchecked Sendable {
    var lastSignalled: pid_t?
    var counts: [pid_t: Int] = [:]
}

/// Adds one small **real** delay — not swallowed by a no-op like `InstantSleeper` — before
/// `slowTarget`'s very first poll, then answers every call instantly afterward, including
/// every other target's. See
/// `testQuitEscalatesASlowSurvivorRatherThanAbandoningItToTheFastestSession` for why a real
/// delay, not a virtual one, is what makes that test a genuine discriminator between
/// `reapAllForQuit`'s nested task-group shape and the brief's flat one.
private final class SlowSecondSignalSleeper: ReaperSleeping, @unchecked Sendable {
    private let slowTarget: pid_t
    private let lastSignalled: () -> pid_t?
    private var hasDelayed = false

    init(slowTarget: pid_t, lastSignalled: @escaping () -> pid_t?) {
        self.slowTarget = slowTarget
        self.lastSignalled = lastSignalled
    }

    func sleep(seconds: Double) async {
        guard !hasDelayed, lastSignalled() == slowTarget else { return }
        hasDelayed = true
        try? await Task.sleep(nanoseconds: 60_000_000)
    }
}

private final class FakePersistence: SessionPersisting {
    var stored: SessionSnapshot?
    func load() -> SessionSnapshot? { stored }
    func save(_ snapshot: SessionSnapshot) { stored = snapshot }
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
        store.processInspector = inspector
        let a = store.newSession(in: URL(fileURLWithPath: "/tmp"))
        let b = store.newSession(in: URL(fileURLWithPath: "/tmp"))
        store.processRegistry.restore([
            a.id: SessionProcess(identity: .init(pid: 601, procStart: 100)),
            b.id: SessionProcess(identity: .init(pid: 602, procStart: 100)),
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
        store.processInspector = FakeInspector(living: [601])
        let a = store.newSession(in: URL(fileURLWithPath: "/tmp"))
        store.processRegistry.restore([
            a.id: SessionProcess(identity: .init(pid: 601, procStart: 100))
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
        store.processInspector = inspector
        let a = store.newSession(in: URL(fileURLWithPath: "/tmp"))
        store.processRegistry.restore([
            a.id: SessionProcess(identity: .init(pid: 601, procStart: 100))
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

    /// Pins Ruling 10's other half: a budget expiry must not erase the survivor it could not
    /// kill. `HangingSleeper` never lets its ladder finish on its own, so the deadline task is
    /// what has to win `reapAllForQuit`'s race here — unlike every other test in this file,
    /// which uses `InstantSleeper` and therefore never actually exercises that branch.
    func testQuitReturnsOnBudgetAndKeepsTheSurvivorsRecordForNextLaunch() async {
        let inspector = FakeInspector(living: [601])   // nothing ever kills it
        let persistence = FakePersistence()
        let store = SessionStore(
            provider: StubProvider(),
            persistence: persistence,
            reaper: SessionReaper(
                inspector: inspector, signals: SpySignals(), sleeper: HangingSleeper()
            )
        )
        store.processInspector = inspector
        let a = store.newSession(in: URL(fileURLWithPath: "/tmp"))
        let process = SessionProcess(identity: .init(pid: 601, procStart: 100))
        store.processRegistry.restore([a.id: process])

        let start = Date()
        await store.reapAllForQuit(budget: 0.2)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertLessThan(
            elapsed, 2.0,
            "must return once the budget expires, not hang on an unkillable target"
        )
        XCTAssertEqual(
            store.processRegistry.process(for: a.id), process,
            "a budget expiry must not erase the survivor — it is the only record the next "
                + "launch's sweep has to find it by"
        )
        XCTAssertEqual(
            persistence.stored?.processes?[a.id.uuidString], process,
            "the persisted snapshot must still name the survivor, not just the in-memory registry"
        )
    }

    /// Pins the ruling this task exists to enforce, in a way `testQuitReapsEveryLiveSession`
    /// cannot: `SessionReaper.escalate` sends a target's first signal before it ever checks
    /// `Task.isCancelled`, so both sessions reach `deliver` at least once regardless of which
    /// task-group shape `reapAllForQuit` uses — a regression back to the brief's flat shape
    /// (one `group.next()`/`cancelAll()` racing the *fastest* reap rather than the aggregate
    /// of all of them) would still turn that test green.
    ///
    /// Here 601 dies on its only signal while 602 survives SIGHUP and needs a second signal,
    /// SIGTERM, to actually die — with a small **real** delay (not swallowed by
    /// `InstantSleeper`) inserted before 602's very first poll. That delay is long enough for
    /// the fast-dying 601 to finish first: under the flat shape, `group.next()` would resolve
    /// on 601 alone and `cancelAll()` would fire while 602 is still asleep inside that first
    /// rung; `Task.sleep`-backed cancellation aborts that sleep promptly, so 602's ladder would
    /// stop after SIGHUP alone and never reach SIGTERM. Under the correct nested shape, no
    /// cancellation reaches 602 at all — the whole aggregate is awaited — so it is escalated to
    /// SIGTERM and dies as scripted.
    func testQuitEscalatesASlowSurvivorRatherThanAbandoningItToTheFastestSession() async {
        let tracker = SignalTracker()
        let inspector = FakeInspector(living: [601, 602])
        let signals = SpySignals()
        signals.onSend = { pid in
            tracker.lastSignalled = pid
            tracker.counts[pid, default: 0] += 1
            if pid == 601 {
                inspector.living.remove(601)                    // dies on its only signal, SIGHUP
            } else if pid == 602, tracker.counts[602] == 2 {
                inspector.living.remove(602)                    // dies only on its second, SIGTERM
            }
        }
        let store = SessionStore(
            provider: StubProvider(),
            persistence: nil,
            reaper: SessionReaper(
                inspector: inspector, signals: signals,
                sleeper: SlowSecondSignalSleeper(slowTarget: 602) { tracker.lastSignalled }
            )
        )
        store.processInspector = inspector
        let a = store.newSession(in: URL(fileURLWithPath: "/tmp"))
        let b = store.newSession(in: URL(fileURLWithPath: "/tmp"))
        store.processRegistry.restore([
            a.id: SessionProcess(identity: .init(pid: 601, procStart: 100)),
            b.id: SessionProcess(identity: .init(pid: 602, procStart: 100)),
        ])

        await store.reapAllForQuit(budget: 5)

        XCTAssertEqual(
            tracker.counts[602], 2,
            "602 must be escalated all the way to SIGTERM, not abandoned the moment 601 finishes"
        )
    }
}
