import XCTest
@testable import FlightDeck

@MainActor
final class CodexRuntimeAttachmentTests: XCTestCase {
    private var dir: URL!
    private var index: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        index = dir.appendingPathComponent("session_index.jsonl")
        FileManager.default.createFile(atPath: index.path, contents: Data())
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func rollout(named name: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        FileManager.default.createFile(atPath: url.path, contents: Data())
        return url
    }

    private func append(_ text: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    private func indexLine(_ id: UUID, _ name: String) -> String {
        #"{"id":"\#(id.uuidString.lowercased())","thread_name":"\#(name)"}"# + "\n"
    }

    private let turn = #"{"type":"event_msg","payload":{"type":"task_started"}}"# + "\n"

    func testTurnsAndRenamesBothReachTheAttachedTab() throws {
        let id = UUID()
        let url = try rollout(named: "a.jsonl")
        let runtime = CodexRuntime(indexURL: index)

        var seen: [AgentEvent] = []
        runtime.attach(AgentBinding(conversationID: id, transcriptURL: url)) { seen.append($0) }
        runtime.drainForTesting() // prime both watchers

        try append(turn, to: url)
        try append(indexLine(id, "renamed"), to: index)
        runtime.drainForTesting()

        XCTAssertEqual(seen, [.activity(.busy), .title("renamed")])
    }

    func testEachTabOnlySeesItsOwnThread() throws {
        let mine = UUID(), theirs = UUID()
        let mineURL = try rollout(named: "mine.jsonl")
        let theirsURL = try rollout(named: "theirs.jsonl")
        let runtime = CodexRuntime(indexURL: index)

        var mineSeen: [AgentEvent] = [], theirsSeen: [AgentEvent] = []
        runtime.attach(AgentBinding(conversationID: mine, transcriptURL: mineURL)) { mineSeen.append($0) }
        runtime.attach(AgentBinding(conversationID: theirs, transcriptURL: theirsURL)) { theirsSeen.append($0) }
        runtime.drainForTesting()

        try append(turn, to: mineURL)
        try append(indexLine(theirs, "theirs renamed"), to: index)
        runtime.drainForTesting()

        XCTAssertEqual(mineSeen, [.activity(.busy)])
        XCTAssertEqual(theirsSeen, [.title("theirs renamed")])
    }

    func testDetachingStopsEverythingForThatTab() throws {
        let id = UUID()
        let url = try rollout(named: "a.jsonl")
        let runtime = CodexRuntime(indexURL: index)

        var seen: [AgentEvent] = []
        let binding = AgentBinding(conversationID: id, transcriptURL: url)
        runtime.attach(binding) { seen.append($0) }
        runtime.drainForTesting()
        runtime.detach(binding)

        try append(turn, to: url)
        try append(indexLine(id, "after detach"), to: index)
        runtime.drainForTesting()

        XCTAssertEqual(seen, [], "a closed tab must not be written to")
    }

    /// A restored tab whose thread was renamed while the app was closed is NOT this watcher's
    /// job — `rebind`'s `thread/read` settles that. Tailing from the end is what keeps a
    /// reopened app from replaying every rename in the user's history across every tab.
    func testAttachingDoesNotReplayRenamesThatPredateIt() throws {
        let id = UUID()
        let url = try rollout(named: "a.jsonl")
        try append(indexLine(id, "renamed while we were closed"), to: index)

        var seen: [AgentEvent] = []
        let runtime = CodexRuntime(indexURL: index)
        runtime.attach(AgentBinding(conversationID: id, transcriptURL: url)) { seen.append($0) }
        runtime.drainForTesting()

        XCTAssertEqual(seen, [])
    }

    func testATabWithNoTranscriptStillGetsRenames() throws {
        let id = UUID()
        let runtime = CodexRuntime(indexURL: index)

        var seen: [AgentEvent] = []
        runtime.attach(AgentBinding(conversationID: id, transcriptURL: nil)) { seen.append($0) }
        runtime.drainForTesting()

        try append(indexLine(id, "still named"), to: index)
        runtime.drainForTesting()

        XCTAssertEqual(seen, [.title("still named")])
    }
}
