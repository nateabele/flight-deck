// Tests/FlightDeckTests/OrphanSweepTests.swift
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
final class OrphanSweepTests: XCTestCase {
    private func snapshot(
        owner: ProcessIdentity?, processes: [String: SessionProcess]
    ) -> SessionSnapshot {
        var s = SessionSnapshot()
        s.owner = owner
        s.processes = processes
        return s
    }

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

    /// A v1 snapshot has neither field. It must decode and sweep nothing.
    func testALegacySnapshotDecodesAndSweepsNothing() async throws {
        let legacy = #"{"sessions":[],"sessionCounter":0}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(SessionSnapshot.self, from: legacy)
        XCTAssertNil(decoded.processes)
        XCTAssertNil(decoded.owner)

        let signals = SpySignals()
        await store(inspector: FakeInspector(living: []), signals: signals)
            .sweepOrphans(from: decoded)

        XCTAssertTrue(signals.targets.isEmpty)
    }

    /// The interlock: the writing instance is still running, so those are its live children.
    func testDoesNotSweepWhenTheOwnerIsStillAlive() async {
        let owner = ProcessIdentity(pid: 500, procStart: 100)
        let orphan = SessionProcess(
            identity: ProcessIdentity(pid: 600, procStart: 100), pgid: 600
        )
        let signals = SpySignals()

        await store(inspector: FakeInspector(living: [500, 600]), signals: signals)
            .sweepOrphans(from: snapshot(owner: owner, processes: [UUID().uuidString: orphan]))

        XCTAssertTrue(signals.targets.isEmpty)
    }

    func testSweepsALiveOrphanWhenTheOwnerIsGone() async {
        let owner = ProcessIdentity(pid: 500, procStart: 100)   // not in `living`
        let orphan = SessionProcess(
            identity: ProcessIdentity(pid: 600, procStart: 100), pgid: 600
        )
        let inspector = FakeInspector(living: [600])
        let signals = SpySignals()
        signals.onSend = { _ in inspector.living.remove(600) }

        await store(inspector: inspector, signals: signals)
            .sweepOrphans(from: snapshot(owner: owner, processes: [UUID().uuidString: orphan]))

        XCTAssertEqual(signals.targets, [600])
    }

    /// The recorded pid was recycled by an unrelated process. Never signal it.
    func testDoesNotSweepARecycledPid() async {
        let owner = ProcessIdentity(pid: 500, procStart: 100)
        let stale = SessionProcess(
            identity: ProcessIdentity(pid: 600, procStart: 42), pgid: 600
        )
        let signals = SpySignals()

        await store(inspector: FakeInspector(living: [600]), signals: signals)
            .sweepOrphans(from: snapshot(owner: owner, processes: [UUID().uuidString: stale]))

        XCTAssertTrue(signals.targets.isEmpty)
    }

    func testSnapshotRoundTripsTheNewFields() throws {
        let s = snapshot(
            owner: ProcessIdentity(pid: 1, procStart: 2),
            processes: ["tab": SessionProcess(
                identity: ProcessIdentity(pid: 3, procStart: 4), pgid: 5
            )]
        )

        let data = try JSONEncoder().encode(s)
        let back = try JSONDecoder().decode(SessionSnapshot.self, from: data)

        XCTAssertEqual(back, s)
    }
}
