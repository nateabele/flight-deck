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

    /// **The escape hatch that keeps `testOnlyReportsChanges` above from making a reset
    /// one-way.** `SessionStore` demotes a tab's readiness when no registry row names its
    /// conversation — to `.absent` on a confirmed death, `.unknown` on weaker evidence,
    /// regardless of what this map last held for it — and the deaths that demotion exists for
    /// are exactly the ones that log no `SessionEnd`, so for a tab this map DOES hold `.live`
    /// for, it is still holding it when the demotion happens. A claude resumed in that tab
    /// reuses the same `session_id`, so its `SessionStart` would fold to `.live`, compare
    /// equal, and never be emitted: the store would stay wherever the demotion left it — the
    /// legacy screen grammar after `.unknown`, or refusing every injection after `.absent` —
    /// for the rest of the process's life. Safe, and silently the feature switching itself
    /// off.
    func testForgettingASessionMakesItsNextEventNewsAgain() throws {
        var batches: [[UUID: ComposerReadiness]] = []
        let watcher = HookEventWatcher(directory: dir, clock: nil) { batches.append($0) }
        try append("SessionStart", a)
        watcher.drain()
        XCTAssertEqual(batches.count, 1, "the premise")

        watcher.forget(a)
        try append("SessionStart", a)
        watcher.drain()

        XCTAssertEqual(batches.count, 2, "a forgotten session's next event is news, not a repeat")
        XCTAssertEqual(batches.last?[a], .live)
    }

    /// Forgetting is per session, not a flush. A shared log carries every tab's events, so a
    /// reset on one tab must not make every other tab re-announce itself into the store.
    func testForgettingOneSessionLeavesAnotherDeduped() throws {
        var batches: [[UUID: ComposerReadiness]] = []
        let watcher = HookEventWatcher(directory: dir, clock: nil) { batches.append($0) }
        try append("SessionStart", a)
        try append("SessionStart", b)
        watcher.drain()

        watcher.forget(a)
        try append("PreToolUse", a)
        try append("PreToolUse", b)
        watcher.drain()

        XCTAssertEqual(batches.count, 2)
        XCTAssertEqual(batches.last?.keys.map { $0 }, [a],
                       "only the forgotten session re-reports")
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

    /// Simulates a relaunch: the shared log already carries a stale `.live` for `a` from a
    /// session the previous run never got a graceful `SessionEnd` for (`SessionReaper` tears
    /// sessions down by signal escalation, not a clean exit). Session ids are stable across
    /// resume, so replaying that backlog would attach the stale `.live` to the *resumed*
    /// tab and suppress the `.unknown` fallback during exactly the window it exists to
    /// cover — this pins that the watcher never does that, while still picking up events
    /// that arrive after it exists.
    func testDoesNotReplayContentThatPredatesConstruction() throws {
        try append("SessionStart", a)

        var seen: [UUID: ComposerReadiness] = [:]
        let watcher = HookEventWatcher(directory: dir, clock: nil) { seen.merge($0) { _, n in n } }
        watcher.drain()
        XCTAssertNil(seen[a], "content already on disk at construction must not be replayed")

        try append("SessionStart", b)
        watcher.drain()
        XCTAssertEqual(seen[b], .live, "an event appended after construction is still read")
    }
}

@MainActor
final class HookEventWatcherDialogTests: XCTestCase {
    /// The dialog callback is fed by the same drain as readiness: a PermissionRequest that
    /// carries no call id is attributed through the PreToolUse logged just before it.
    func testPermissionRequestIsAttributedThroughTheWatcher() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fd-hook-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let sid = UUID()
        var got: [DialogAttribution.Change] = []
        let watcher = HookEventWatcher(directory: dir, clock: nil, onChange: { _ in },
                                       onDialog: { got += $0 })
        let base = #""session_id":"\#(sid.uuidString.lowercased())","tool_name":"Bash","tool_input":{"command":"rm -rf x"}"#
        let lines = #"{"hook_event_name":"PreToolUse",\#(base),"agent_id":"a28ad87b","tool_use_id":"toolu_X"}"# + "\n"
            + #"{"hook_event_name":"PermissionRequest",\#(base)}"# + "\n"
        try Data(lines.utf8).write(to: dir.appendingPathComponent("events.ndjson"))
        watcher.drain()
        XCTAssertEqual(got, [.raised(sid, PendingDialog(agentID: "a28ad87b", callID: "toolu_X"))])
    }
}
