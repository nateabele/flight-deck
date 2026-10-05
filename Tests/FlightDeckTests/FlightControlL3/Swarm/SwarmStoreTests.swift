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
}
