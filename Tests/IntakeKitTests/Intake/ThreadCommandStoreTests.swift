import XCTest
import IntakeKit

/// `threads/commands.jsonl` (R8), the file the app and the phone append thread commands to and
/// ThreadRunner reads: the same one-line-per-command, seq-numbered contract as the tape's
/// `commands.jsonl`, so the same torn-line and unknown-kind rules hold.
final class ThreadCommandStoreTests: XCTestCase {
    private var root: URL!
    private let thread = ThreadID(UUID())

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ThreadCommandStore-\(UUID())", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    func testItLivesUnderThreadsAndIsMadeOnFirstAppend() throws {
        let store = ThreadCommandStore(intakeDirectory: root)
        XCTAssertEqual(store.commandsURL.path, root.appendingPathComponent("threads").appendingPathComponent("commands.jsonl").path)
        XCTAssertTrue(store.commands(after: 0).isEmpty, "no file yet is no commands")
        XCTAssertEqual(try store.append(.resolve(thread)), 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.commandsURL.path))
    }

    func testAppendsNumberInOrderAndReadAfterASeq() throws {
        let store = ThreadCommandStore(intakeDirectory: root)
        let open = ThreadCommand.open(thread, .wholePlan, title: "T", agent: .codex, model: "m", effort: "high")
        let message = ThreadCommand.message(thread, text: "Why?", messageID: "m1", source: nil, elementID: nil, subjectRevision: nil)
        XCTAssertEqual(try store.append(open), 1)
        XCTAssertEqual(try store.append(message), 2)
        XCTAssertEqual(try store.append(.resolve(thread)), 3)
        XCTAssertEqual(store.commands(after: 0), [ThreadCommandEnvelope(seq: 1, command: open),
                                                  ThreadCommandEnvelope(seq: 2, command: message),
                                                  ThreadCommandEnvelope(seq: 3, command: .resolve(thread))])
        XCTAssertEqual(store.commands(after: 2).map(\.seq), [3])
        let text = try String(contentsOf: store.commandsURL, encoding: .utf8)
        XCTAssertEqual(text.split(separator: "\n").count, 3, "one line per command")
    }

    /// A crashed append's torn last line is skipped on read and closed off before the next
    /// append, so the next command is never glued onto it.
    func testATornLineIsSkippedAndTheNextAppendStandsAlone() throws {
        let store = ThreadCommandStore(intakeDirectory: root)
        _ = try store.append(.resolve(thread))
        let handle = try FileHandle(forWritingTo: store.commandsURL)
        handle.seekToEndOfFile()
        handle.write(Data(#"{"seq":2,"command":{"kind":"reo"#.utf8))
        try handle.close()
        XCTAssertEqual(store.commands(after: 0).map(\.seq), [1])
        XCTAssertEqual(try store.append(.reopen(thread)), 2)
        XCTAssertEqual(store.commands(after: 0).map(\.command), [.resolve(thread), .reopen(thread)])
    }

    /// A kind a later build wrote is dropped, and its seq still counts.
    func testAnUnknownKindIsDroppedButHoldsItsSeq() throws {
        let store = ThreadCommandStore(intakeDirectory: root)
        try FileManager.default.createDirectory(at: store.commandsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let future = #"{"seq":5,"command":{"kind":"makeVisual","thread":"\#(thread.raw.uuidString)"}}"# + "\n"
        try Data(future.utf8).write(to: store.commandsURL)
        XCTAssertTrue(store.commands(after: 0).isEmpty)
        XCTAssertEqual(try store.append(.resolve(thread)), 6)
    }
}
