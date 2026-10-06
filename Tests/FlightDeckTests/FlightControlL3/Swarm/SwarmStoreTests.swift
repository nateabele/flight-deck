import XCTest
import IntakeKit
@testable import FlightDeck

/// swarms.json is what a relaunch reads, and the one rule it carries is spec §2's: a swarm that
/// was running comes back paused, with a banner, and claims nothing until a human resumes it.
@MainActor
final class SwarmStoreTests: XCTestCase {
    private var root: URL!
    private let at = Date(timeIntervalSince1970: 1_790_000_000)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("swarm-store-\(UUID().uuidString)")
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func record(_ state: SwarmState, project: String = "/p") -> SwarmRecord {
        SwarmRecord(id: UUID(), project: project, cap: 3, poolCaps: [:], filter: .allReady,
                    state: state, agents: [], createdAt: at)
    }

    func testSaveThenLoadRoundTrips() {
        let store = SwarmStore(root: root)
        let records = [record(.running), record(.stopped, project: "/q")]
        store.save(records)
        XCTAssertEqual(SwarmStore(root: root).load(), records)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("swarms.json").path))
    }

    func testRestoreBringsRunningAndDrainingBackPausedWithBanner() {
        let store = SwarmStore(root: root)
        store.save([record(.running, project: "/a"), record(.draining, project: "/b"),
                    record(.paused, project: "/c"), record(.stopped, project: "/d")])
        let restored = SwarmStore(root: root).restore()
        XCTAssertEqual(restored.map(\.state), [.paused, .paused, .paused, .stopped])
        XCTAssertEqual(restored.map(\.banner), [SwarmStore.restartBanner, SwarmStore.restartBanner, nil, nil])
        XCTAssertEqual(SwarmStore.restartBanner, "Swarm paused after restart · Resume")
    }

    func testMissingOrCorruptFileLoadsEmpty() throws {
        XCTAssertEqual(SwarmStore(root: root).load(), [])
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: root.appendingPathComponent("swarms.json"))
        XCTAssertEqual(SwarmStore(root: root).load(), [], "a corrupt file must not crash the app at launch")
    }

    func testLogAppendsOneLinePerEntryPerSwarm() throws {
        let store = SwarmStore(root: root)
        let a = UUID(), b = UUID()
        store.append(SwarmLogEntry(at: at, kind: .launch, detail: "cap 3"), swarm: a)
        store.append(SwarmLogEntry(at: at, kind: .claim, task: "fx-a", detail: "BlueLake"), swarm: a)
        store.append(SwarmLogEntry(at: at, kind: .pause), swarm: b)
        XCTAssertEqual(store.log(swarm: a).map(\.kind), [.launch, .claim])
        XCTAssertEqual(store.log(swarm: b).map(\.kind), [.pause])
        let text = try String(contentsOf: root.appendingPathComponent("swarm-log/\(a.uuidString).jsonl"), encoding: .utf8)
        XCTAssertEqual(text.split(separator: "\n").count, 2)
    }

    func testDefaultRootFollowsTheStateDirectoryHelper() {
        XCTAssertEqual(SwarmStore.defaultRoot(stateDirectory: nil), FileSessionPersistence.defaultDirectory())
        let custom = URL(fileURLWithPath: "/tmp/custom-state", isDirectory: true)
        XCTAssertEqual(SwarmStore.defaultRoot(stateDirectory: custom), custom)
    }

    /// A file that does not decode loads empty (the app must launch), and the next save would
    /// overwrite the only copy of every swarm in it. It is moved aside first.
    func testACorruptFileIsMovedAsideNotOverwritten() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: root.appendingPathComponent("swarms.json"))
        let store = SwarmStore(root: root)
        XCTAssertEqual(store.load(), [])
        store.save([record(.running)])
        let aside = try XCTUnwrap(try FileManager.default.contentsOfDirectory(atPath: root.path)
            .first { $0.hasPrefix("swarms.json.corrupt-") })
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent(aside), encoding: .utf8), "not json")
        XCTAssertEqual(store.load().count, 1)
    }

    /// A newer build's file is not this build's to rewrite in the old format.
    func testANewerVersionsFileIsMovedAsideNotOverwritten() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let newer = #"{"v":2,"swarms":[]}"#
        try Data(newer.utf8).write(to: root.appendingPathComponent("swarms.json"))
        let store = SwarmStore(root: root)
        XCTAssertEqual(store.load(), [])
        store.save([record(.running)])
        let aside = try XCTUnwrap(try FileManager.default.contentsOfDirectory(atPath: root.path)
            .first { $0.hasPrefix("swarms.json.v2-") })
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent(aside), encoding: .utf8), newer)
    }
}
