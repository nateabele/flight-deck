import XCTest
@testable import FlightDeck

@MainActor
final class CodexRolloutWatcherTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private let started = #"{"type":"event_msg","payload":{"type":"task_started"}}"# + "\n"
    private let completed = #"{"type":"event_msg","payload":{"type":"task_complete"}}"# + "\n"

    func testReportsTurnBoundariesAppendedAfterStart() throws {
        let url = dir.appendingPathComponent("rollout.jsonl")
        FileManager.default.createFile(atPath: url.path, contents: Data())

        var seen: [AgentEvent] = []
        let watcher = CodexRolloutWatcher(url: url) { seen.append($0) }
        watcher.drain() // prime while empty

        try (started + completed).data(using: .utf8)!.write(to: url)
        watcher.drain()

        XCTAssertEqual(seen, [.activity(.busy), .activity(.idle), .turnEnded])
    }

    /// The rollout exists, carrying an ~18 KB `session_meta` header, before any terminal
    /// does — `thread/start` creates it and returns its path. Tailing from the end is
    /// therefore correct: the header is not a turn. Do not "fix" this into reading from 0.
    func testSkipsTheHeaderThatExistedBeforeWatchingBegan() throws {
        let url = dir.appendingPathComponent("rollout.jsonl")
        let header = #"{"type":"session_meta","payload":{"id":"x"}}"# + "\n"
        try (header + started + completed).data(using: .utf8)!.write(to: url)

        var seen: [AgentEvent] = []
        let watcher = CodexRolloutWatcher(url: url) { seen.append($0) }
        watcher.drain()

        XCTAssertEqual(seen, [], "everything already in the file predates this watcher")

        try (header + started + completed + started).data(using: .utf8)!.write(to: url)
        watcher.drain()
        XCTAssertEqual(seen, [.activity(.busy)], "only the appended turn is news")
    }
}
