// Tests/FlightDeckTests/OrphanSweepTests.swift
import XCTest
@testable import FlightDeck

private final class StubProvider: SurfaceProvider {
    func makeSurface(_ config: Ghostty.SurfaceConfiguration) -> Ghostty.SurfaceView? { nil }
    func tick() {}
}

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

    /// The path every existing user takes on first launch after this ships: a real v1
    /// `sessions.json` already on disk, with neither `processes` nor `owner`, loaded through
    /// the actual `FileSessionPersistence` rather than an in-memory stand-in. Must both
    /// restore its tabs and leave the sweep a no-op — `testALegacySnapshotDecodesAndSweepsNothing`
    /// above proves the in-memory shape; this proves the on-disk one end to end.
    func testALegacyFileOnDiskRestoresAndSweepsNothing() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("OrphanSweepTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }

        let id = UUID()
        let json = """
        {"sessions":[{"id":"\(id.uuidString)","title":"a","workingDirectory":"/tmp"}],\
        "sessionCounter":1}
        """
        try Data(json.utf8).write(
            to: dir.appendingPathComponent("sessions.json", isDirectory: false)
        )

        let persistence = FileSessionPersistence(directory: dir, legacyDefaults: nil)
        let loaded = try XCTUnwrap(persistence.load())
        XCTAssertNil(loaded.processes)
        XCTAssertNil(loaded.owner)

        let signals = SpySignals()
        let s = SessionStore(
            provider: StubProvider(),
            persistence: persistence,
            reaper: SessionReaper(
                inspector: FakeInspector(living: []), signals: signals, sleeper: InstantSleeper()
            )
        )
        s.processInspector = FakeInspector(living: [])

        XCTAssertTrue(s.restore())
        XCTAssertEqual(s.repos.flatMap(\.sessions).map(\.id), [id])

        await s.sweepOrphans(from: loaded)

        XCTAssertTrue(signals.targets.isEmpty)
    }

    /// The interlock: the writing instance is still running, so those are its live children.
    func testDoesNotSweepWhenTheOwnerIsStillAlive() async {
        let owner = ProcessIdentity(pid: 500, procStart: 100)
        let orphan = SessionProcess(
            identity: ProcessIdentity(pid: 600, procStart: 100)
        )
        let signals = SpySignals()

        await store(inspector: FakeInspector(living: [500, 600]), signals: signals)
            .sweepOrphans(from: snapshot(owner: owner, processes: [UUID().uuidString: orphan]))

        XCTAssertTrue(signals.targets.isEmpty)
    }

    /// Fails closed, not open: a snapshot whose provenance cannot be established (no
    /// `owner` at all — a truncated/hand-edited file, a nil identity read at write time, or
    /// a future writer that skips `persist()`) must never be treated as safe to sweep. The
    /// identity gate cannot substitute here — a live instance's own recorded children pass
    /// `isAlive` by design, which is exactly what would make them killable if this fell
    /// through instead of returning.
    func testDoesNotSweepWhenTheOwnerIsNil() async {
        let orphan = SessionProcess(
            identity: ProcessIdentity(pid: 600, procStart: 100)
        )
        let signals = SpySignals()

        await store(inspector: FakeInspector(living: [600]), signals: signals)
            .sweepOrphans(from: snapshot(owner: nil, processes: [UUID().uuidString: orphan]))

        XCTAssertTrue(signals.targets.isEmpty)
    }

    func testSweepsALiveOrphanWhenTheOwnerIsGone() async {
        let owner = ProcessIdentity(pid: 500, procStart: 100)   // not in `living`
        let orphan = SessionProcess(
            identity: ProcessIdentity(pid: 600, procStart: 100)
        )
        let inspector = FakeInspector(living: [600])
        let signals = SpySignals()
        signals.onSend = { _ in inspector.living.remove(600) }

        await store(inspector: inspector, signals: signals)
            .sweepOrphans(from: snapshot(owner: owner, processes: [UUID().uuidString: orphan]))

        XCTAssertEqual(signals.targets, [600])
    }

    /// The regression this sweep exists to prevent: nothing on the record is ever the target.
    /// Only the group the live process table reports right now — for a pid this sweep has just
    /// positively identified — gets signalled. (`SessionProcess` no longer even carries a
    /// `pgid`; this test is what stops one being reintroduced and trusted.)
    func testSweepSignalsTheLiveGroupNotTheRecordedPid() async {
        let owner = ProcessIdentity(pid: 500, procStart: 100)
        let orphan = SessionProcess(
            identity: ProcessIdentity(pid: 600, procStart: 100)
        )
        let inspector = FakeInspector(living: [600])
        inspector.pgids = [600: 650]   // what the live process table actually reports
        let signals = SpySignals()
        signals.onSend = { _ in inspector.living.remove(600) }

        await store(inspector: inspector, signals: signals)
            .sweepOrphans(from: snapshot(owner: owner, processes: [UUID().uuidString: orphan]))

        XCTAssertEqual(signals.targets, [650], "must signal the live group, never the recorded pid")
    }

    /// When the live process table cannot establish a group for an otherwise-verified
    /// orphan, the sweep must never guess one — `reap` receives `nil` and falls back to
    /// signalling the pid directly, never a sentinel `killpg` target.
    func testSweepSignalsThePidDirectlyWhenTheLivePgidIsUnknown() async {
        let owner = ProcessIdentity(pid: 500, procStart: 100)   // not in `living`
        let orphan = SessionProcess(
            identity: ProcessIdentity(pid: 600, procStart: 100)
        )
        let inspector = FakeInspector(living: [600])
        inspector.noPgidFor = [600]
        let signals = SpySignals()
        signals.onSend = { _ in inspector.living.remove(600) }

        await store(inspector: inspector, signals: signals)
            .sweepOrphans(from: snapshot(owner: owner, processes: [UUID().uuidString: orphan]))

        XCTAssertEqual(signals.perPidTargets, [600], "must fall back to a direct signal")
        XCTAssertEqual(signals.targets.count, signals.perPidTargets.count, "never a group send")
    }

    /// The recorded pid was recycled by an unrelated process. Never signal it.
    func testDoesNotSweepARecycledPid() async {
        let owner = ProcessIdentity(pid: 500, procStart: 100)
        let stale = SessionProcess(
            identity: ProcessIdentity(pid: 600, procStart: 42)
        )
        let signals = SpySignals()

        await store(inspector: FakeInspector(living: [600]), signals: signals)
            .sweepOrphans(from: snapshot(owner: owner, processes: [UUID().uuidString: stale]))

        XCTAssertTrue(signals.targets.isEmpty)
    }

    /// The other half of Critical 1's fix: a survivor the sweep could not kill must not vanish
    /// the moment anything else in this run calls `persist()`. `processRegistry` starts every
    /// run empty — nothing here forked these children — so unless the sweep puts the survivor
    /// back into it, the very next unrelated save (a tab switch, a new session) would silently
    /// drop the one record the *next* launch's sweep needs to find it by.
    func testASurvivorIsKeptInTheRegistryAndPersistedForTheNextLaunch() async {
        let owner = ProcessIdentity(pid: 500, procStart: 100)   // not in `living`
        let survivorID = UUID()
        let survivor = SessionProcess(
            identity: ProcessIdentity(pid: 600, procStart: 100)
        )
        let inspector = FakeInspector(living: [600])   // nothing ever kills it
        let persistence = FakePersistence()
        let s = SessionStore(
            provider: StubProvider(),
            persistence: persistence,
            reaper: SessionReaper(
                inspector: inspector, signals: SpySignals(), sleeper: InstantSleeper()
            )
        )
        s.processInspector = inspector

        await s.sweepOrphans(
            from: snapshot(owner: owner, processes: [survivorID.uuidString: survivor])
        )

        // *Some* record, not the old key's. The old key is a previous run's tab id, which this
        // run has already reused for a live tab of its own; asserting on it would have pinned
        // exactly the collision the sweep must not cause.
        XCTAssertEqual(
            Array(s.processRegistry.all.values), [survivor],
            "an unkilled orphan must be re-recorded, not just reported and forgotten"
        )
        XCTAssertEqual(
            persistence.stored?.processes.map { Array($0.values) }, [survivor],
            "must reach disk too, or the very next unrelated persist() silently drops it"
        )
    }

    /// The collision the fresh key exists to prevent. `restore()` recreates this run's tabs
    /// under the *same* UUIDs the previous run persisted, and records a brand-new shell against
    /// each one; the sweep runs afterwards. Re-keying a survivor under its old id would replace
    /// that live tab's real record with a dead run's orphan — a live process discarded without
    /// any proof of death, never reaped on close or quit, and gone from the next snapshot too.
    func testASurvivorDoesNotOverwriteALiveTabRecordedUnderTheSameID() async {
        let owner = ProcessIdentity(pid: 500, procStart: 100)   // not in `living`
        let sharedID = UUID()
        let orphan = SessionProcess(identity: ProcessIdentity(pid: 600, procStart: 100))
        let liveShell = SessionProcess(identity: ProcessIdentity(pid: 700, procStart: 100))
        let inspector = FakeInspector(living: [600, 700])   // nothing ever kills either
        let s = store(inspector: inspector, signals: SpySignals())
        // What this run's own `insertSession` would have recorded for the restored tab.
        s.processRegistry.keep(sharedID, as: liveShell)

        await s.sweepOrphans(
            from: snapshot(owner: owner, processes: [sharedID.uuidString: orphan])
        )

        XCTAssertEqual(
            s.processRegistry.process(for: sharedID), liveShell,
            "the live tab's own shell must still be the record under its id"
        )
        XCTAssertTrue(
            s.processRegistry.all.values.contains(orphan),
            "and the survivor must still be kept, under a key of its own"
        )
    }

    func testSnapshotRoundTripsTheNewFields() throws {
        let s = snapshot(
            owner: ProcessIdentity(pid: 1, procStart: 2),
            processes: ["tab": SessionProcess(
                identity: ProcessIdentity(pid: 3, procStart: 4)
            )]
        )

        let data = try JSONEncoder().encode(s)
        let back = try JSONDecoder().decode(SessionSnapshot.self, from: data)

        XCTAssertEqual(back, s)
    }
}
