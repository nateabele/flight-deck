// Tests/FlightDeckTests/SurfaceProcessRegistryTests.swift
import XCTest
@testable import FlightDeck

/// A process table a test drives by hand. `children` is whatever `living` currently says, so a
/// test stages a fork by inserting a pid between polls — which is what the real thing does, on
/// libghostty's IO thread, well after `makeSurface` has returned.
private final class FakeTable: ProcessInspecting, @unchecked Sendable {
    var living: Set<pid_t> = []
    init(living: Set<pid_t> = []) { self.living = living }

    func children(of ppid: pid_t) -> Set<pid_t> { living }
    func descendants(of pid: pid_t) -> [ProcessIdentity] { [] }
    func startTime(of pid: pid_t) -> UInt64? { living.contains(pid) ? UInt64(pid) * 10 : nil }
    func isAlive(_ identity: ProcessIdentity) -> Bool { living.contains(identity.pid) }
    /// Never consulted: the registry records no pgid, because every signal path re-derives the
    /// group from the live table at the moment it signals. Present only to satisfy the protocol.
    func pgid(of pid: pid_t) -> pid_t? { nil }
}

/// Runs the poll loop as fast as the main actor will go, and lets a test fork a process "on the
/// IO thread" at a chosen poll. Each `sleep` is one tick of `SurfaceProcessRegistry`'s loop.
private final class ScriptedSleeper: ReaperSleeping, @unchecked Sendable {
    var polls = 0
    /// Called before each poll returns, with the poll's 1-based number.
    ///
    /// Hopped onto the main actor deliberately. `ReaperSleeping.sleep` is nonisolated, so the
    /// registry's poll loop leaves the main actor to call it — which is the whole point of the
    /// seam — and a hook that touched the registry from there would trap. The main actor is
    /// merely *suspended* awaiting this call, not blocked, so the hop lands immediately and the
    /// poll still resumes in a fully determined order.
    var onPoll: (@MainActor (Int) -> Void)?

    func sleep(seconds: Double) async {
        polls += 1
        let poll = polls
        if let onPoll { await MainActor.run { onPoll(poll) } }
        await Task.yield()
    }
}

@MainActor
final class SurfaceProcessRegistryTests: XCTestCase {
    private let tab = UUID()
    private let other = UUID()

    /// Lets the registry's background resolution `Task` run to completion. It is main-actor
    /// bound and finite (`pollBudget` polls at most), so yielding repeatedly drains it without
    /// any real waiting — `ScriptedSleeper` never actually sleeps.
    private func drain() async {
        for _ in 0..<600 { await Task.yield() }
    }

    private func registry(_ table: FakeTable, _ sleeper: ScriptedSleeper) -> SurfaceProcessRegistry {
        SurfaceProcessRegistry(inspector: table, sleeper: sleeper)
    }

    /// The premise of the whole rewrite: nothing has forked by the time `makeSurface` returns,
    /// and the record still appears once the IO thread gets around to it.
    func testRecordsAChildThatOnlyAppearsAfterMakeReturns() async {
        let table = FakeTable(living: [10, 11])
        let sleeper = ScriptedSleeper()
        sleeper.onPoll = { poll in if poll == 3 { table.living.insert(12) } }
        let r = registry(table, sleeper)

        let made = r.record(for: tab) { "surface" }
        XCTAssertEqual(made, "surface")
        XCTAssertNil(r.process(for: tab), "nothing has forked yet — the old synchronous diff saw exactly this")

        await drain()

        XCTAssertEqual(r.process(for: tab)?.identity.pid, 12)
        XCTAssertEqual(r.process(for: tab)?.identity.procStart, 120)
    }

    /// The resolution must not block the caller: `record` returns before any polling happens.
    func testRecordReturnsWithoutWaitingForTheFork() {
        let table = FakeTable(living: [10])
        let sleeper = ScriptedSleeper()
        let r = registry(table, sleeper)

        _ = r.record(for: tab) { "surface" }

        XCTAssertEqual(sleeper.polls, 0, "record must not have driven the poll loop synchronously")
    }

    /// Surface creation failed, so there is no IO thread and there will be no fork. Recording
    /// nothing is the point; so is not starting a poll loop that would sit there claiming
    /// whatever unrelated child happened to appear.
    func testANilSurfaceQueuesNoResolutionAtAll() async {
        let table = FakeTable(living: [10])
        let sleeper = ScriptedSleeper()
        sleeper.onPoll = { _ in table.living.insert(99) }
        let r = registry(table, sleeper)

        let made: String? = r.record(for: tab) { nil }

        XCTAssertNil(made)
        await drain()
        XCTAssertEqual(sleeper.polls, 0)
        XCTAssertNil(r.process(for: tab))
    }

    /// The deadline. A shell that never appears leaves the tab with no record, which degrades
    /// to libghostty's SIGHUP-only teardown rather than to a guess.
    func testRecordsNothingWhenNoChildEverAppears() async {
        let table = FakeTable(living: [10])
        let sleeper = ScriptedSleeper()
        let r = registry(table, sleeper)

        r.record(for: tab) { "surface" }
        await drain()

        XCTAssertNil(r.process(for: tab))
        XCTAssertEqual(
            sleeper.polls, SurfaceProcessRegistry.pollBudget,
            "must give up on a bounded number of polls, not poll forever"
        )
    }

    /// Two pids that could only have come from this one request: surface creation forks exactly
    /// one child, so this is the process table saying something we do not understand. Same
    /// conservatism the synchronous diff had for `new.count > 1`.
    func testRecordsNothingWhenTwoChildrenAppearForOneTab() async {
        let table = FakeTable(living: [10])
        let sleeper = ScriptedSleeper()
        sleeper.onPoll = { poll in if poll == 2 { table.living.formUnion([20, 21]) } }
        let r = registry(table, sleeper)

        r.record(for: tab) { "surface" }
        await drain()

        XCTAssertNil(r.process(for: tab))
    }

    // MARK: - Claim tracking

    /// The hazard that shapes the design. Both tabs are created before either shell forks, so
    /// neither pid is attributable to one request rather than the other. Recording *either* one
    /// would mean closing one tab kills the other's process tree — worse than recording nothing.
    func testTwoTabsRacingWithIndistinguishableForksRecordNothing() async {
        let table = FakeTable(living: [10])
        let sleeper = ScriptedSleeper()
        sleeper.onPoll = { poll in if poll == 2 { table.living.formUnion([20, 21]) } }
        let r = registry(table, sleeper)

        r.record(for: tab) { "surface" }
        r.record(for: other) { "surface" }
        await drain()

        XCTAssertNil(r.process(for: tab), "ambiguous: 20 and 21 could each belong to either tab")
        XCTAssertNil(r.process(for: other))
        // But both are still ours, and both are still killable at quit and on the next launch.
        XCTAssertEqual(Set(r.all.values.map(\.identity.pid)), [20, 21])
        XCTAssertEqual(
            Set(r.all.keys).intersection([tab, other]), [],
            "adopted under keys of their own, so no tab close can signal them"
        )
    }

    /// A child that predates every request in the batch is not ours to adopt. Only pids that
    /// appeared after at least one request started are treated as that batch's forks.
    func testAPreexistingChildIsNeverAdopted() async {
        let table = FakeTable(living: [10, 11])
        let sleeper = ScriptedSleeper()
        let r = registry(table, sleeper)

        r.record(for: tab) { "surface" }
        await drain()

        XCTAssertTrue(r.all.isEmpty, "10 and 11 were already there before the surface existed")
    }

    /// The owner is told once, after the batch settles — not once per claim, and not never.
    /// Records arrive up to half a second after the tab, long after the `persist()` that
    /// created it.
    func testTheOwnerIsNotifiedOnceWhenABatchSettles() async {
        let table = FakeTable(living: [])
        let sleeper = ScriptedSleeper()
        sleeper.onPoll = { poll in if poll == 1 { table.living.insert(7) } }
        let r = registry(table, sleeper)
        var notifications = 0
        r.onChange = { notifications += 1 }

        r.record(for: tab) { "surface" }
        r.record(for: other) { "surface" }
        await drain()

        XCTAssertEqual(notifications, 1)
    }

    /// The same two tabs, but the first one's fork lands before the second is created — so each
    /// pid *is* attributable, and both get recorded correctly. This is the ordering `record`'s
    /// opportunistic claim exists to catch, and the one `restore()` produces when the IO thread
    /// keeps up with the loop rebuilding tabs.
    func testTwoTabsWhoseForksLandInOrderAreEachRecordedCorrectly() async {
        let table = FakeTable(living: [10])
        let sleeper = ScriptedSleeper()
        let r = registry(table, sleeper)

        r.record(for: tab) { "surface" }
        table.living.insert(20)                       // first tab's shell, before the second tab exists
        sleeper.onPoll = { poll in if poll == 2 { table.living.insert(21) } }
        r.record(for: other) { "surface" }
        await drain()

        XCTAssertEqual(r.process(for: tab)?.identity.pid, 20)
        XCTAssertEqual(r.process(for: other)?.identity.pid, 21)
    }

    /// A pid claimed for one tab is never handed to another, even when the second tab is still
    /// looking and that pid is the only new child in the table.
    func testAClaimedPidIsNeverRecordedForASecondTab() async {
        let table = FakeTable(living: [10])
        let sleeper = ScriptedSleeper()
        let r = registry(table, sleeper)

        r.record(for: tab) { "surface" }
        table.living.insert(20)
        r.record(for: other) { "surface" }            // claims 20 for `tab` on the way in
        await drain()

        XCTAssertEqual(r.process(for: tab)?.identity.pid, 20)
        XCTAssertNil(r.process(for: other), "20 belongs to the first tab and to nobody else")
    }

    /// A request that gave up stays in contention. Its fork may still be about to land, and
    /// handing that late pid to a sibling that is still looking would be the cross-assignment
    /// this whole mechanism exists to prevent. Dropping *claimed* requests from contention is
    /// sound; dropping given-up ones is not, and this is the difference.
    ///
    /// Timing: the first tab is created before poll 1 and gives up at poll `pollBudget` (25);
    /// the second is created at poll 20 and gives up at poll 45. Pid 30 lands at poll 30 —
    /// inside that window, with one request given up and the other still looking.
    func testALatePidIsNotHandedToASiblingAfterTheFirstRequestGivesUp() async {
        let table = FakeTable(living: [10])
        let sleeper = ScriptedSleeper()
        var resolver: SurfaceProcessRegistry?
        let second = other
        sleeper.onPoll = { poll in
            if poll == 20 { resolver?.record(for: second) { "surface" } }
            if poll == 30 { table.living.insert(30) }
        }
        let r = registry(table, sleeper)
        resolver = r

        r.record(for: tab) { "surface" }
        await drain()

        XCTAssertNil(r.process(for: tab))
        XCTAssertNil(r.process(for: second), "30 may be the first tab's very late fork")
        XCTAssertEqual(r.all.values.map(\.identity.pid), [30], "adopted, but keyed to no tab")
    }

    /// A pid already recorded against one tab is never a candidate for another, even when it
    /// appears in the table only after the second tab started looking for its own shell.
    func testAnAlreadyRecordedPidIsNotACandidateForALaterTab() async {
        let table = FakeTable(living: [10])
        let sleeper = ScriptedSleeper()
        let r = registry(table, sleeper)

        r.record(for: other) { "surface" }
        r.keep(tab, as: SessionProcess(identity: ProcessIdentity(pid: 20, procStart: 200)))
        table.living.insert(20)
        await drain()

        XCTAssertEqual(r.process(for: tab)?.identity.pid, 20)
        XCTAssertNil(r.process(for: other), "20 is spoken for; the second tab gets nothing")
    }

    // MARK: - Bookkeeping

    func testForgetReturnsAndRemovesTheRecord() async {
        let table = FakeTable(living: [])
        let sleeper = ScriptedSleeper()
        sleeper.onPoll = { poll in if poll == 1 { table.living.insert(7) } }
        let r = registry(table, sleeper)
        r.record(for: tab) { "surface" }
        await drain()

        let forgotten = r.forget(tab)

        XCTAssertEqual(forgotten?.identity.pid, 7)
        XCTAssertNil(r.process(for: tab))
        XCTAssertNil(r.forget(tab))
    }

    func testRestoreRepopulatesFromASnapshot() {
        let r = registry(FakeTable(), ScriptedSleeper())
        let stored = SessionProcess(identity: ProcessIdentity(pid: 88, procStart: 5))

        r.restore([tab: stored])

        XCTAssertEqual(r.all, [tab: stored])
    }

    /// `SessionProcess` used to carry a `pgid`. Snapshots written before it was removed must
    /// still decode — synthesized `Codable` ignores keys it does not know — or the first launch
    /// after this change would throw on load and drop every tab.
    func testASnapshotCarryingTheOldPgidKeyStillDecodes() throws {
        let legacy = #"{"identity":{"pid":42,"procStart":99},"pgid":42}"#.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(SessionProcess.self, from: legacy)

        XCTAssertEqual(decoded.identity, ProcessIdentity(pid: 42, procStart: 99))
    }
}
