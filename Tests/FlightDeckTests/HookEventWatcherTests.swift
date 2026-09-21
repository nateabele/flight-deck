import XCTest
@testable import FlightDeck

@MainActor
final class HookEventWatcherTests: XCTestCase {
    private var dir: URL!
    private let a = UUID(uuidString: "b16a1e73-b93e-4493-a396-46adc4cf02ee")!
    private let b = UUID(uuidString: "c27b2f84-c04f-45a4-b407-57bed5df13ff")!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fd-hook-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func append(_ event: String, _ id: UUID) throws {
        let line = #"{"hook_event_name":"\#(event)","session_id":"\#(id.uuidString.lowercased())"}"# + "\n"
        let url = dir.appendingPathComponent("events.ndjson")
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try handle.close()
        } else {
            try Data(line.utf8).write(to: url)
        }
    }

    func testReportsReadinessPerSession() throws {
        var seen: [UUID: ComposerReadiness] = [:]
        let watcher = HookEventWatcher(directory: dir, clock: nil) { changes in
            seen.merge(changes) { _, new in new }
        }
        try append("SessionStart", a)
        try append("SessionStart", b)
        try append("SessionEnd", b)
        watcher.drain()

        XCTAssertEqual(seen[a], .live)
        XCTAssertEqual(seen[b], .absent, "two sessions must not blur together")
    }

    func testOnlyReportsChanges() throws {
        var batches: [[UUID: ComposerReadiness]] = []
        let watcher = HookEventWatcher(directory: dir, clock: nil) { batches.append($0) }
        try append("SessionStart", a)
        watcher.drain()
        try append("PostToolUse", a)
        try append("Stop", a)
        watcher.drain()

        XCTAssertEqual(batches.first?[a], .live)
        XCTAssertEqual(
            batches.count, 1,
            "a second read that only reconfirms .live must not re-emit"
        )
    }

    func testAMissingDirectoryIsNotAnError() {
        let watcher = HookEventWatcher(
            directory: dir.appendingPathComponent("nope"), clock: nil
        ) { _ in XCTFail("nothing to report") }
        watcher.drain()
    }

    func testGarbageLinesAreSkippedWithoutLosingLaterOnes() throws {
        var seen: [UUID: ComposerReadiness] = [:]
        let watcher = HookEventWatcher(directory: dir, clock: nil) { seen.merge($0) { _, n in n } }
        let url = dir.appendingPathComponent("events.ndjson")
        try Data("garbage\n".utf8).write(to: url)
        try append("SessionStart", a)
        watcher.drain()

        XCTAssertEqual(seen[a], .live)
    }
}
