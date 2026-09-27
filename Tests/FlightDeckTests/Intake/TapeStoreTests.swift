import XCTest
import IntakeKit

final class TapeStoreTests: XCTestCase {
    var root: URL!
    override func setUp() { root = FileManager.default.temporaryDirectory.appendingPathComponent("tapes-\(UUID())") }
    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    // MARK: - tape.json

    func testSaveLoadRoundTrip() throws {
        let store = TapeStore(intakeDirectory: root)
        var tape = Tape.empty
        tape.checkpoints = [Checkpoint(id: 1, stage: .draft, round: 0, major: true, createdAt: Date(timeIntervalSince1970: 1000))]
        tape.target = .nextMajor
        tape.status = .running
        tape.extraRefinement = 1
        tape.pendingAnnotations = ["watch the schema"]
        try store.saveTape(tape)
        XCTAssertEqual(store.loadTape(), tape)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.tapeURL.path))
    }

    func testCorruptTapeLoadsAsEmpty() throws {
        let store = TapeStore(intakeDirectory: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("{".utf8).write(to: store.tapeURL)
        XCTAssertEqual(store.loadTape(), .empty)
    }

    func testMissingTapeLoadsAsEmpty() {
        let store = TapeStore(intakeDirectory: root)
        XCTAssertEqual(store.loadTape(), .empty)
    }

    // MARK: - commands.jsonl

    func testAppendCommandAssignsSequentialSeq() throws {
        let store = TapeStore(intakeDirectory: root)
        XCTAssertEqual(try store.appendCommand(.step), 1)
        XCTAssertEqual(try store.appendCommand(.nextMajor), 2)
        XCTAssertEqual(try store.appendCommand(.pause), 3)
    }

    func testCommandsAfterSeqReturnsOnlyLater() throws {
        let store = TapeStore(intakeDirectory: root)
        _ = try store.appendCommand(.step)
        _ = try store.appendCommand(.nextMajor)
        _ = try store.appendCommand(.toReview)
        let after = store.commands(after: 1)
        XCTAssertEqual(after.map(\.seq), [2, 3])
        XCTAssertEqual(after.map(\.command), [.nextMajor, .toReview])
    }

    func testAnnotateAndExtendRoundTripThroughCommandsFile() throws {
        let store = TapeStore(intakeDirectory: root)
        _ = try store.appendCommand(.annotate("watch the schema"))
        _ = try store.appendCommand(.extend(.refine, by: 2))
        let commands = store.commands(after: 0).map(\.command)
        XCTAssertEqual(commands, [.annotate("watch the schema"), .extend(.refine, by: 2)])
    }

    func testTornFinalLineIsSkippedNotFatal() throws {
        let store = TapeStore(intakeDirectory: root)
        _ = try store.appendCommand(.step)
        _ = try store.appendCommand(.nextMajor)
        // Simulate a crash mid-append: a partial, unterminated line with no trailing newline.
        let handle = try FileHandle(forWritingTo: store.commandsURL)
        handle.seekToEndOfFile()
        handle.write(Data("{\"seq\":3,\"comman".utf8))
        try handle.close()

        let all = store.commands(after: 0)
        XCTAssertEqual(all.map(\.seq), [1, 2])

        // The store must still be usable after the torn line — the next append picks up
        // seq 3, not seq 4, because the torn line never counted as a real command.
        XCTAssertEqual(try store.appendCommand(.pause), 3)

        // And the append must have closed out the torn line with its own newline first —
        // otherwise this command would be glued onto "...comman" and fail to decode, silently
        // losing a pause/stop the caller just asked for.
        let afterAppend = store.commands(after: 0)
        XCTAssertEqual(afterAppend.map(\.seq), [1, 2, 3])
        XCTAssertEqual(afterAppend.map(\.command), [.step, .nextMajor, .pause])
    }

    func testCommandsFileHasOneLinePerCommand() throws {
        let store = TapeStore(intakeDirectory: root)
        _ = try store.appendCommand(.step)
        _ = try store.appendCommand(.annotate("note"))
        let text = try String(contentsOf: store.commandsURL, encoding: .utf8)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        XCTAssertEqual(lines.count, 2)
    }

    // MARK: - checkpoints

    func testWriteCheckpointWritesFilesBeforeUpdatingTape() throws {
        let store = TapeStore(intakeDirectory: root)
        var tape = Tape.empty
        let cp = Checkpoint(id: 1, stage: .draft, round: 0, major: true, createdAt: Date())
        try store.writeCheckpoint(cp, files: ["draft.md": Data("hello".utf8)], into: &tape)

        XCTAssertEqual(tape.checkpoints, [cp])
        XCTAssertEqual(store.loadTape().checkpoints, [cp])
        let fileURL = store.checkpointDirectory(1).appendingPathComponent("draft.md")
        XCTAssertEqual(try Data(contentsOf: fileURL), Data("hello".utf8))
    }

    /// A draft round's files are keyed `drafts/<i>.md` — a relative path whose own parent
    /// doesn't exist yet inside the fresh checkpoint directory.
    func testWriteCheckpointCreatesSubdirectoriesForNestedFiles() throws {
        let store = TapeStore(intakeDirectory: root)
        var tape = Tape.empty
        let cp = Checkpoint(id: 1, stage: .draft, round: 0, major: true, createdAt: Date())
        try store.writeCheckpoint(cp, files: ["drafts/0.md": Data("zero".utf8), "drafts/2.md": Data("two".utf8)], into: &tape)
        let drafts = store.checkpointDirectory(1).appendingPathComponent("drafts")
        XCTAssertEqual(try Data(contentsOf: drafts.appendingPathComponent("0.md")), Data("zero".utf8))
        XCTAssertEqual(try Data(contentsOf: drafts.appendingPathComponent("2.md")), Data("two".utf8))
        XCTAssertEqual(tape.checkpoints, [cp])
    }

    func testWriteCheckpointRemovesAnOrphanDirectoryFirst() throws {
        let store = TapeStore(intakeDirectory: root)
        // Simulate a prior crash: checkpoints/7/ exists with a stale file, but tape.json
        // never got the checkpoint appended (the crash happened between the two writes).
        let orphanDir = store.checkpointDirectory(7)
        try FileManager.default.createDirectory(at: orphanDir, withIntermediateDirectories: true)
        try Data("stale from the dead attempt".utf8).write(to: orphanDir.appendingPathComponent("stale.txt"))
        try Data("also stale".utf8).write(to: orphanDir.appendingPathComponent("draft.md"))

        var tape = Tape.empty
        let cp = Checkpoint(id: 7, stage: .draft, round: 0, major: true, createdAt: Date())
        try store.writeCheckpoint(cp, files: ["draft.md": Data("fresh content".utf8)], into: &tape)

        let dir = store.checkpointDirectory(7)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("stale.txt").path))
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("draft.md")), Data("fresh content".utf8))
        XCTAssertEqual(tape.checkpoints, [cp])
    }

    func testOrphanCheckpointDirectoryWithNoTapeEntryIsIgnoredByLoad() throws {
        let store = TapeStore(intakeDirectory: root)
        var tape = Tape.empty
        try store.saveTape(tape)
        // An orphan directory with no corresponding tape entry (as a crash between writing
        // checkpoint files and saving the tape would leave behind).
        let orphanDir = store.checkpointDirectory(7)
        try FileManager.default.createDirectory(at: orphanDir, withIntermediateDirectories: true)
        try Data("orphan".utf8).write(to: orphanDir.appendingPathComponent("draft.md"))

        // loadTape only reads tape.json — the orphan directory is invisible to it.
        XCTAssertEqual(store.loadTape(), tape)
        XCTAssertTrue(store.loadTape().checkpoints.isEmpty)
    }
}
