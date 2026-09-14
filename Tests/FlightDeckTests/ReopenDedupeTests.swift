// Tests/FlightDeckTests/ReopenDedupeTests.swift
import XCTest
@testable import FlightDeck

// `StubProvider` lives in its own file now — see that file's doc comment.

private final class FakeInspector: ProcessInspecting, @unchecked Sendable {
    var living: Set<pid_t>
    /// Overrides what `pgid(of:)` reports for a pid, so a test can stage a live group that
    /// disagrees with a persisted one. Unset pids fall back to reporting themselves as their
    /// own group, mirroring the common `setsid` case.
    var pgids: [pid_t: pid_t] = [:]
    /// Pids for which `pgid(of:)` should report "could not be established" (`nil`), distinct
    /// from an absent entry in `pgids` — which still falls back to reporting the pid itself.
    var noPgidFor: Set<pid_t> = []
    init(living: Set<pid_t>) { self.living = living }
    func children(of ppid: pid_t) -> Set<pid_t> { [] }
    func descendants(of pid: pid_t) -> [ProcessIdentity] { [] }
    func startTime(of pid: pid_t) -> UInt64? { living.contains(pid) ? 100 : nil }
    func isAlive(_ identity: ProcessIdentity) -> Bool {
        living.contains(identity.pid) && identity.procStart == 100
    }
    func pgid(of pid: pid_t) -> pid_t? {
        noPgidFor.contains(pid) ? nil : (pgids[pid] ?? pid)
    }
}

private final class SpySignals: SignalSending, @unchecked Sendable {
    var targets: [pid_t] = []
    /// Recorded separately from `targets` so a test can tell a `killpg` from a `kill` — the
    /// distinction the nil-pgid fallback exists to guarantee.
    var perPidTargets: [pid_t] = []
    var onSend: ((pid_t) -> Void)?
    func send(_ signal: Int32, toGroup pgid: pid_t) -> Bool {
        targets.append(pgid); onSend?(pgid); return true
    }
    func send(_ signal: Int32, toProcess pid: pid_t) -> Bool {
        targets.append(pid); perPidTargets.append(pid); onSend?(pid); return true
    }
    func ownProcessGroup() -> pid_t { 999 }
}

private struct InstantSleeper: ReaperSleeping {
    func sleep(seconds: Double) async {}
}

private final class FakePersistence: SessionPersisting {
    var stored: SessionSnapshot?
    func load() -> SessionSnapshot? { stored }
    func save(_ snapshot: SessionSnapshot) { stored = snapshot }
}

@MainActor
final class ReopenDedupeTests: XCTestCase {
    /// The same fake feeds both the reaper (which decides when a target has died) and the
    /// store's own liveness checks (which decide what is worth signalling at all).
    private func store(
        inspector: ProcessInspecting, signals: SignalSending
    ) -> SessionStore {
        let s = SessionStore(
            provider: StubProvider(),
            persistence: nil,
            reaper: SessionReaper(
                inspector: inspector, signals: signals, sleeper: InstantSleeper()
            )
        )
        s.processInspector = inspector
        return s
    }

    /// The pure capture: which live pids are already resuming this conversation.
    func testDuplicateResumePidsPicksEveryRowOnTheConversation() {
        let conversation = UUID()
        let other = UUID()
        let rows: [pid_t: ClaudeStatusFile.Entry] = [
            3404: .init(pid: 3404, sessionID: conversation, activity: .idle, waitingFor: nil,
                        startedAt: 1, cwd: "/w", procStart: "old"),
            77: .init(pid: 77, sessionID: other, activity: .busy, waitingFor: nil,
                      startedAt: 1, cwd: "/w", procStart: "x"),
        ]
        XCTAssertEqual(
            SessionStore.duplicateResumePids(conversation: conversation, in: rows), [3404]
        )
    }

    /// The async reap: a captured, still-live duplicate identity is signalled; the reaper's
    /// identity gate is satisfied via processInspector (NOT the registry row's string time).
    func testReapResumeDuplicatesSignalsTheLiveStaleProcess() async {
        let signals = SpySignals()
        let inspector = FakeInspector(living: [3404])   // isAlive requires procStart == 100
        let store = store(inspector: inspector, signals: signals)

        await store.reapResumeDuplicates(
            [ProcessIdentity(pid: 3404, procStart: 100)], context: "reopen dedupe test"
        )

        XCTAssertTrue(signals.targets.contains(3404),
                      "the stale duplicate process must be reaped")
    }

    /// A pid that is no longer alive is skipped, not signalled (no wrong-process kill).
    func testReapResumeDuplicatesSkipsADeadPid() async {
        let signals = SpySignals()
        let inspector = FakeInspector(living: [])   // nothing alive
        let store = store(inspector: inspector, signals: signals)

        await store.reapResumeDuplicates(
            [ProcessIdentity(pid: 3404, procStart: 100)], context: "reopen dedupe test"
        )

        XCTAssertTrue(signals.targets.isEmpty)
    }

    /// The recycle guard: the identity was captured at reopen time with `procStart: 999`, but
    /// pid 3404 is alive now under a *different* start time (100) — a different process that
    /// merely recycled the pid. `isAlive` gates on the captured identity, not on "is the pid
    /// alive at all", so this must be skipped, never signalled.
    func testReapResumeDuplicatesSkipsAPidRecycledSinceCapture() async {
        let signals = SpySignals()
        let inspector = FakeInspector(living: [3404])   // alive, but only at procStart == 100
        let store = store(inspector: inspector, signals: signals)

        await store.reapResumeDuplicates(
            [ProcessIdentity(pid: 3404, procStart: 999)], context: "reopen dedupe test"
        )

        XCTAssertTrue(signals.targets.isEmpty,
                      "a pid recycled since capture must not be signalled")
    }
}
