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

        XCTAssertEqual(
            seen,
            [.lifecycle(.live), .activity(.busy), .activity(.idle), .turnEnded],
            "a line landing at all is boot evidence, ahead of whatever it decodes to"
        )
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

        XCTAssertEqual(
            seen, [],
            "everything already in the file predates this watcher — attaching alone must "
            + "not read as .live, or a tab attached before codex has booted would bypass "
            + "the screen gate for the whole boot window"
        )

        try (header + started + completed + started).data(using: .utf8)!.write(to: url)
        watcher.drain()
        XCTAssertEqual(
            seen, [.lifecycle(.live), .activity(.busy)],
            "only the appended turn is news, but it is now news on two axes: the turn "
            + "boundary AND the first confirmation this process is actually writing"
        )
    }

    /// `.lifecycle(.live)` is evidence that codex's TUI is up and writing, not a claim about
    /// what it wrote — `CodexEventMapper` alone decides which lines carry turn events, and a
    /// line it does not recognise (a future record shape, or genuine garbage) still proves
    /// the process is alive. Un-parseable content must not silently forfeit that signal.
    func testAnUnrecognisedLineStillSignalsLifecycleLiveEvenThoughItMapsToNoEvent() throws {
        let url = dir.appendingPathComponent("rollout.jsonl")
        FileManager.default.createFile(atPath: url.path, contents: Data())

        var seen: [AgentEvent] = []
        let watcher = CodexRolloutWatcher(url: url) { seen.append($0) }
        watcher.drain() // prime while empty

        try "not json at all\n".data(using: .utf8)!.write(to: url)
        watcher.drain()

        XCTAssertEqual(seen, [.lifecycle(.live)])
    }

    /// A poll that finds nothing new — the ordinary steady-state tick between turns — must
    /// not re-announce `.live` on every tick. `ComposerReadiness` only distinguishes
    /// live/not-live, so a repeat is harmless to the reducer, but a watcher that emits on
    /// every empty poll would still be lying about what it observed.
    func testAnEmptyPollEmitsNothing() throws {
        let url = dir.appendingPathComponent("rollout.jsonl")
        FileManager.default.createFile(atPath: url.path, contents: Data())

        var seen: [AgentEvent] = []
        let watcher = CodexRolloutWatcher(url: url) { seen.append($0) }
        watcher.drain() // prime
        watcher.drain() // nothing appended since

        XCTAssertEqual(seen, [])
    }

    /// The other of `TailReader`'s two "does the file exist yet" orderings — the one its own
    /// comment calls "deliberately not symmetric" with the pre-existing-file case above. This
    /// is the routine production shape, not an edge case: `CodexAdapter.prepare` hands
    /// `CodexRolloutWatcher` a computed path (`AgentBinding.transcriptURL`) before codex's
    /// TUI has necessarily written anything there, so the watcher is constructed against a
    /// URL with nothing on disk far more often than against one that already has a header.
    ///
    /// `TailReader` answers "no file yet" by marking its start chosen but leaving `offset` at
    /// 0 rather than fast-forwarding to a size it cannot read — so once the file appears, the
    /// NEXT poll reads it from byte 0, not from wherever it happened to have grown to. That
    /// is exactly why this ordering needs its own test: the pre-existing-file case above
    /// proves the gate does not fire on stale bytes it skips past, but says nothing about
    /// whether it fires correctly once a file starts from nothing.
    func testTheFirstLineEverWrittenStillGatesLifecycleLiveWhenTheFileDidNotExistAtAttach() throws {
        let url = dir.appendingPathComponent("rollout.jsonl") // never created before this

        var seen: [AgentEvent] = []
        let watcher = CodexRolloutWatcher(url: url) { seen.append($0) }
        watcher.drain() // the file does not exist yet — must not read as .live

        XCTAssertEqual(
            seen, [],
            "no file on disk is not evidence of anything; a gate that fired here would mark "
            + "a tab ready before codex's TUI has so much as been spawned"
        )

        let header = #"{"type":"session_meta","payload":{"id":"x"}}"# + "\n"
        try (header + started + completed).data(using: .utf8)!.write(to: url)
        watcher.drain()

        XCTAssertEqual(
            seen,
            [.lifecycle(.live), .activity(.busy), .activity(.idle), .turnEnded],
            "the file's first-ever content is read from byte 0 once it appears, unlike the "
            + "pre-existing-file case, and must gate .live exactly once, leading the events "
            + "it introduces"
        )
    }
}
