import AppKit
import SwiftUI
import XCTest
import FleetKit
import IntakeKit
@testable import FlightDeck

/// L3-S drew a stand-in meter so its UI tests had something to see; L3-U built the real one.
/// After integration the stand-in must be gone everywhere — two meters that disagree about an
/// account would be worse than none.
@MainActor
final class MeterMountTests: XCTestCase {
    func testNoStandInMeterRemainsInSources() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let sources = root.appendingPathComponent("Sources/FlightDeck")
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var scanned = 0
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            scanned += 1
            let text = try String(contentsOf: url, encoding: .utf8)
            XCTAssertFalse(text.contains("MinimalMeter"), "\(url.lastPathComponent) still uses the stand-in meter")
        }
        XCTAssertGreaterThan(scanned, 100, "the scan must actually find the sources")
    }

    func testSwarmRowShowsRealMeterPastSoft() throws {
        let rig = try L3IntegrationRig.standard()
        let work = try XCTUnwrap(rig.accountID("Work"))
        rig.feed(account: "Work", utilization: 0.85)
        XCTAssertNotNil(MeterFormatter.rowMeter(account: work, ledger: rig.usage.ledger, now: rig.now),
                        "past soft → the row draws a mini meter")
        rig.feed(account: "Work", utilization: 0.40)
        XCTAssertNil(MeterFormatter.rowMeter(account: work, ledger: rig.usage.ledger, now: rig.now))
    }

    func testAnnotationNamesTheLeasedAccountSoTheRowCanAskTheFormatter() async throws {
        let rig = try L3IntegrationRig.standard()
        rig.feed(account: "Work", utilization: 0.30)
        try await rig.launch(cap: 1)
        await rig.tick()
        let spawn = try XCTUnwrap(rig.spawns.first)
        rig.feed(account: "Work", utilization: 0.85)
        let annotation = try XCTUnwrap(rig.swarm.annotation(for: spawn.session.id, now: rig.now))
        XCTAssertEqual(annotation.meterAccount, rig.accountID("Work"))
        XCTAssertNotNil(annotation.meter)
    }

    func testPopoverPoolsAreOnlyThePoolsTheSwarmUses() async throws {
        let rig = try L3IntegrationRig.standard()
        rig.addPool(id: "unused-pool", accounts: ["Personal"])
        rig.feed(account: "Work", utilization: 0.30)
        try await rig.launch(cap: 1)
        await rig.tick()
        let pools = rig.swarm.meterPools(forProject: rig.project, ledger: rig.usage.ledger, now: rig.now)
        XCTAssertEqual(pools.map(\.id), ["codex-default"], "a pool no agent leases from is not this swarm's business")
        XCTAssertFalse(pools.first?.accounts.isEmpty ?? true)
    }

    func testPhoneMetersCarryTheLedgerHeadroom() async throws {
        let rig = try L3IntegrationRig.standard()
        rig.feed(account: "Work", utilization: 0.30)
        try await rig.launch(cap: 1)
        await rig.tick()
        rig.feed(account: "Work", utilization: 0.85)
        let record = try XCTUnwrap(rig.swarm.record(forProject: rig.project))
        let wire = try XCTUnwrap(SwarmWireProjection.wire(record, service: rig.swarm, now: rig.now))
        let work = try XCTUnwrap(wire.meters.first { $0.accountName == "Work" })
        XCTAssertEqual(try XCTUnwrap(work.utilization), 0.85, accuracy: 0.001)
        XCTAssertEqual(work.state, "overSoft")
        XCTAssertEqual(work.pool, "codex-default")
    }

    // MARK: - mounted views follow the ledger

    /// Re-lays-out the host until `done` holds, for at most two seconds. SwiftUI applies a published
    /// change on a later runloop turn, so a fixed sleep either flakes under load or wastes time;
    /// a bounded poll is as fast as the machine allows and still fails when the view never updates.
    private func settle(_ host: NSView, until done: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(2)
        repeat {
            host.layoutSubtreeIfNeeded()
            if done() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        } while Date() < deadline
        host.layoutSubtreeIfNeeded()
        return done()
    }

    func testRowMeterAppearsAndDisappearsWithReadingsAlone() async throws {
        let rig = try L3IntegrationRig.standard()
        let work = try XCTUnwrap(rig.accountID("Work"))
        rig.feed(account: "Work", utilization: 0.30)
        // The annotation is deliberately frozen with NO cached meter: only the live ledger moves.
        let frozen = SwarmSessionAnnotation(taskChip: nil, contested: false, meter: nil, meterAccount: work,
                                            marker: nil, lastActive: nil)
        let host = NSHostingView(rootView: SwarmRowChips(annotation: frozen, usage: rig.usage))
        host.frame = NSRect(x: 0, y: 0, width: 200, height: 20)
        host.layoutSubtreeIfNeeded()
        let under = host.fittingSize.width
        rig.feed(account: "Work", utilization: 0.85)
        let appeared = await settle(host) { host.fittingSize.width > under }
        XCTAssertTrue(appeared, "crossing soft must draw the meter with no other state change")
        rig.feed(account: "Work", utilization: 0.40)
        let gone = await settle(host) { host.fittingSize.width == under }
        XCTAssertTrue(gone, "dropping under soft must remove it, though the cached annotation never changed")
    }

    func testRowMeterDoesNotLingerWhenTheCachedAnnotationSaidOverSoft() async throws {
        let rig = try L3IntegrationRig.standard()
        let work = try XCTUnwrap(rig.accountID("Work"))
        rig.feed(account: "Work", utilization: 0.30)
        let stale = SwarmSessionAnnotation(taskChip: nil, contested: false, meter: 0.9, meterAccount: work,
                                           marker: nil, lastActive: nil)
        let host = NSHostingView(rootView: SwarmRowChips(annotation: stale, usage: rig.usage))
        host.frame = NSRect(x: 0, y: 0, width: 200, height: 20)
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(host.fittingSize.width, 0, accuracy: 0.5, "the live ledger is under soft, whatever the cache says")
    }

    func testDrawerAssignmentMeterIsPopulatedForALeasedAgentAndLive() async throws {
        let rig = try L3IntegrationRig.standard()
        rig.feed(account: "Work", utilization: 0.30)
        try await rig.launch(cap: 1)
        await rig.tick()
        let spawn = try XCTUnwrap(rig.spawns.first)
        let detail = try XCTUnwrap(rig.swarm.assignment(for: spawn.session.id, now: rig.now))
        let ref = try XCTUnwrap(detail.meter, "a leased agent's assignment lane carries its account meter")
        XCTAssertEqual(ref.account, rig.accountID("Work"))
        XCTAssertEqual(ref.pool, "codex-default")
        rig.feed(account: "Work", utilization: 0.85)
        let model = try XCTUnwrap(ref.model(ledger: rig.usage.ledger, now: rig.now))
        XCTAssertEqual(try XCTUnwrap(model.fraction), 0.85, accuracy: 0.001, "built from the live ledger, not frozen at assignment time")
        XCTAssertEqual(model.state, .overSoft)
    }

    /// The host's pixels. Accessibility is not reachable for an unshown hosting view, but a
    /// drawn bar and its text are, and "different pixels" is exactly what is asserted.
    private func pixels(_ host: NSView) -> Data? {
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep.tiffRepresentation
    }

    private func mountDrawer(_ detail: SwarmAssignmentDetail, usage: UsageService) -> NSHostingView<ObserveDrawer> {
        let agent = FlywheelProjection.Agent(name: "BlueLake", bead: nil, status: .active, holds: [], waitsOn: [],
                                             lastEventAt: nil, stalledSince: nil)
        let host = NSHostingView(rootView: ObserveDrawer(
            agent: agent, collapsed: false, onToggleCollapse: {}, onJumpToRootCause: {}, onOpenDAG: {},
            assignment: detail, usage: usage))
        host.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        return host
    }

    /// The assignment lane mounted for real: the meter bar must be there for a leased agent and
    /// must follow a reading with nothing else changing. A drawer that dropped its
    /// `UsageService` observation, or the bar, would pass every model test and fail this one.
    func testDrawerAssignmentLaneDrawsTheMeterBarAndFollowsReadings() async throws {
        let rig = try L3IntegrationRig.standard()
        rig.feed(account: "Work", utilization: 0.30)
        try await rig.launch(cap: 1)
        await rig.tick()
        let spawn = try XCTUnwrap(rig.spawns.first)
        let detail = try XCTUnwrap(rig.swarm.assignment(for: spawn.session.id, now: rig.now))
        var bare = detail
        bare.meter = nil
        let without = try XCTUnwrap(pixels(mountDrawer(bare, usage: rig.usage)))
        let host = mountDrawer(detail, usage: rig.usage)
        let low = try XCTUnwrap(pixels(host))
        XCTAssertNotEqual(low, without, "the leased account's meter bar is drawn in the lane")
        rig.feed(account: "Work", utilization: 0.85)
        let followed = await settle(host) { self.pixels(host) != low }
        XCTAssertTrue(followed, "the bar follows a reading with no other state change")
    }

    func testPopoverPoolsFollowTheLiveLedger() async throws {
        let rig = try L3IntegrationRig.standard()
        rig.feed(account: "Work", utilization: 0.30)
        try await rig.launch(cap: 1)
        await rig.tick()
        let record = try XCTUnwrap(rig.swarm.record(forProject: rig.project))
        let summary = try XCTUnwrap(rig.swarm.summary(forProject: rig.project))
        var seen: [Double?] = []
        let view = SwarmPopover(record: record, pools: { ledger, now in
            let pools = rig.swarm.meterPools(forProject: rig.project, ledger: ledger, now: now)
            seen.append(pools.first?.accounts.first { $0.label == "Work" }?.fraction)
            return pools
        }, usage: rig.usage, summary: summary, onPause: {}, onResume: {})
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        host.layoutSubtreeIfNeeded()
        rig.feed(account: "Work", utilization: 0.85)
        let followed = await settle(host) { (seen.last ?? nil) == 0.85 }
        XCTAssertTrue(followed, "an open popover re-reads the ledger when a reading lands (saw \(seen))")
    }

    func testCacheSurvivesAMissingFileThenPicksItUp() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("fd-handoff-missing-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let cache = HandoffHistoryCache(logURL: url)
        await cache.refresh()
        XCTAssertTrue(cache.all.isEmpty)
        let a = UUID()
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        var data = try enc.encode(entry(old: a, new: UUID()))
        data.append(0x0A)
        try data.write(to: url)
        await cache.refresh()
        XCTAssertEqual(cache.entries(for: a).count, 1)
    }

    // MARK: - hand-off history

    private func entry(old: UUID, new: UUID?, outcome: HandoffLogEntry.Outcome = .handedOff, at: TimeInterval = 0) -> HandoffLogEntry {
        HandoffLogEntry(at: Date(timeIntervalSince1970: at), outcome: outcome, task: "fx-1", oldSession: old,
                        oldAgent: "BlueLake", newSession: new, newAgent: new == nil ? nil : "GreenFox",
                        fromAccount: "Work", toAccount: new == nil ? nil : "Personal", detail: nil)
    }

    func testHistoryKeepsOnlyThisSessionsEntriesNewestFirst() {
        let a = UUID(), b = UUID(), c = UUID()
        let lines = HandoffHistory.lines(
            for: b, entries: [entry(old: a, new: b, at: 100), entry(old: c, new: UUID(), at: 150), entry(old: b, new: c, at: 200)],
            timeZone: TimeZone(identifier: "UTC")!, locale: Locale(identifier: "en_US_POSIX"))
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].contains("BlueLake") && lines[0].contains("GreenFox"), lines[0])
        XCTAssertTrue(lines[0].contains("Work") && lines[0].contains("Personal"), lines[0])
    }

    func testParsingSkipsTornAndForeignLines() throws {
        let a = UUID()
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        var data = try enc.encode(entry(old: a, new: UUID()))
        data.append(contentsOf: Array("\nnot json\n{\"half\":".utf8))
        XCTAssertEqual(HandoffHistory.parse(data).count, 1)
    }

    func testCacheReadsOffMainAndPublishesOnce() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("fd-handoff-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let a = UUID(), b = UUID()
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        var data = try enc.encode(entry(old: a, new: b))
        data.append(0x0A)
        try data.write(to: url)
        let cache = HandoffHistoryCache(logURL: url)
        XCTAssertTrue(cache.entries(for: a).isEmpty, "a render never waits on the disk")
        await cache.refresh()
        XCTAssertEqual(cache.entries(for: a).count, 1)
        XCTAssertEqual(cache.entries(for: b).count, 1)
        XCTAssertEqual(cache.reads, 1)
        await cache.refresh()
        XCTAssertEqual(cache.reads, 1, "an unchanged file is not re-read")
    }
}
