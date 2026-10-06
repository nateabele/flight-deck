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
