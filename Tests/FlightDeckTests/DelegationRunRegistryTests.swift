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
}
