import FleetKit
import HostKit
import XCTest
@testable import FlightDeck

@MainActor
final class DelegationRunRegistryTests: XCTestCase {
    private func file() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("fd-runs-\(UUID().uuidString)/delegation.json")
    }

    private func run(_ id: String) -> DelegatedRun {
        var run = DelegatedRun(id: id, hostRunID: "h", host: "mini", owner: nil, kind: .run, command: "make", recipe: nil,
                               state: .running, status: nil, ports: [], startedAt: Date(), worktree: "/w", snapshot: nil,
                               applyMode: .review, request: WireDelegateRun(cwd: "/w"), resultCommit: nil, resultBundle: nil)
        run.include = [".env"]
        run.fetch = ["out/*"]
        return run
    }

    func testRunsAndTheirFetchSurviveARelaunch() {
        let url = file()
        let registry = RunRegistry(file: url)
        let id = registry.mintID()
        registry.add(run(id))
        registry.flush()
        let reloaded = RunRegistry(file: url)
        XCTAssertEqual(reloaded.run(id)?.fetch, ["out/*"])
        XCTAssertEqual(reloaded.run(id)?.include, [".env"])
        XCTAssertNotEqual(reloaded.mintID(), id)
    }

    /// A corrupt file is moved aside, not overwritten by the next save.
    func testACorruptFileIsMovedAside() throws {
        let url = file()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: url)
        let registry = RunRegistry(file: url)
        XCTAssertTrue(registry.runs.isEmpty)
        let aside = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
        XCTAssertTrue(aside.contains { $0.hasPrefix("delegation.json.corrupt-") }, "\(aside)")
    }

    /// The counter is seeded above every id on record, whatever it says itself.
    func testTheCounterStartsAboveEveryIdOnRecord() throws {
        let url = file()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let registry = RunRegistry(file: url)
        registry.add(run("r41"))
        registry.flush()
        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        json["next"] = 2
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        XCTAssertEqual(RunRegistry(file: url).mintID(), "r42")
    }

    /// Ids still legible in a set-aside file are never handed out again.
    func testIdsInACorruptFileAreNotReused() throws {
        let url = file()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"next":3,"runs":[{"id":"r17","host":"mini" BROKEN"#.utf8).write(to: url)
        XCTAssertEqual(RunRegistry(file: url).mintID(), "r18")
    }

    /// A file written before `include`/`fetch` existed still loads.
    func testAnOlderRecordWithoutIncludeOrFetchLoads() throws {
        let url = file()
        let registry = RunRegistry(file: url)
        registry.add(run("r1"))
        registry.flush()
        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        var runs = json["runs"] as! [[String: Any]]
        runs[0]["include"] = nil
        runs[0]["fetch"] = nil
        json["runs"] = runs
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        let reloaded = RunRegistry(file: url)
        XCTAssertEqual(reloaded.run("r1")?.fetch, [])
        XCTAssertEqual(reloaded.run("r1")?.include, [])
    }

    // MARK: Saves

    /// Every change saves, and a save rewrites the whole file (measured 11 ms at 1k runs, 111 ms
    /// at 10k, on main): a burst of changes shares one write, made off the main actor.
    func testABurstOfChangesIsOneWrite() async throws {
        let url = file()
        let registry = RunRegistry(file: url, saveDelay: 0.05)
        let id = registry.mintID()
        registry.add(run(id))
        for status in 0..<50 { registry.update(id) { $0.status = Int32(status) } }
        XCTAssertEqual(registry.writes, 0, "nothing written yet: the changes wait for each other")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        for _ in 0..<200 where registry.writes == 0 { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertEqual(registry.writes, 1)
        registry.flush()
        XCTAssertEqual(RunRegistry(file: url).run(id)?.status, 49, "the last change is the one on disk")
    }

    /// Quitting must not lose a change still waiting out the delay.
    func testFlushWritesAtOnce() {
        let url = file()
        let registry = RunRegistry(file: url, saveDelay: 3600)
        let id = registry.mintID()
        registry.add(run(id))
        registry.flush()
        XCTAssertNotNil(RunRegistry(file: url).run(id))
    }

    // MARK: Retention

    func testAFinishedRunIsStampedWithItsEnd() {
        let registry = RunRegistry(file: nil)
        registry.add(run("r1"))
        XCTAssertNil(registry.run("r1")?.endedAt)
        registry.update("r1") { $0.state = .exited }
        XCTAssertNotNil(registry.run("r1")?.endedAt)
    }

    func testRetentionExpiresOldFinishedRunsAndAllButTheNewest500PerHost() {
        let now = Date()
        let registry = RunRegistry(file: nil)
        func add(_ id: String, host: String, state: DelegatedRun.State, ended: TimeInterval?) {
            var record = DelegatedRun(id: id, hostRunID: id, host: host, owner: nil, kind: .run, command: "make",
                                      recipe: nil, state: state, status: nil, ports: [],
                                      startedAt: now.addingTimeInterval(-30 * 24 * 3600), worktree: "/w", snapshot: nil,
                                      applyMode: .review, request: WireDelegateRun(cwd: "/w"), resultCommit: nil,
                                      resultBundle: nil)
            record.endedAt = ended.map { now.addingTimeInterval(-$0) }
            registry.add(record)
        }
        add("old", host: "mini", state: .exited, ended: 15 * 24 * 3600)
        add("recent", host: "mini", state: .died, ended: 13 * 24 * 3600)
        add("going", host: "mini", state: .running, ended: nil)
        for i in 0..<501 { add("linux\(i)", host: "linux", state: .exited, ended: TimeInterval(i)) }
        XCTAssertEqual(Set(registry.expired(now: now).map(\.id)), ["old", "linux500"],
                       "past 14 days, or the oldest past 500 on one host; never a run still going")
    }
}
