import XCTest
@testable import FlightDeck

final class TailReaderTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func write(_ text: String, to url: URL) throws {
        try text.data(using: .utf8)!.write(to: url)
    }

    /// A file that already existed on the first look predates the watcher, so its history is
    /// not ours to replay — only what is appended afterwards is.
    func testSkipsWhatExistedBeforeTheFirstLook() throws {
        let url = dir.appendingPathComponent("f.jsonl")
        try write("old-a\nold-b\n", to: url)

        let first = TailReader.read(url: url, offset: 0, hasChosenStart: false)
        XCTAssertEqual(first.lines, [], "the first look at an existing file reads nothing")
        XCTAssertTrue(first.hasChosenStart)

        try write("old-a\nold-b\nnew\n", to: url)
        let second = TailReader.read(url: url, offset: first.offset, hasChosenStart: true)
        XCTAssertEqual(second.lines, ["new"])
    }

    /// A file that does not exist yet has no history to skip, so whatever appears there later
    /// is ours from byte 0. Deciding that on the *missing* look is what makes the first
    /// record in a file that springs into existence with content already in it arrive.
    func testReadsFromZeroWhenTheFileDidNotExistYet() throws {
        let url = dir.appendingPathComponent("later.jsonl")

        let first = TailReader.read(url: url, offset: 0, hasChosenStart: false)
        XCTAssertTrue(first.hasChosenStart, "a missing file still settles where reading starts")
        XCTAssertEqual(first.offset, 0)

        try write("born-with-content\n", to: url)
        let second = TailReader.read(url: url, offset: first.offset, hasChosenStart: true)
        XCTAssertEqual(second.lines, ["born-with-content"])
    }

    /// A read can land mid-write, so a trailing line with no newline is held back until it
    /// is whole.
    func testHoldsBackAPartialTrailingLine() throws {
        let url = dir.appendingPathComponent("f.jsonl")
        try write("", to: url)
        let primed = TailReader.read(url: url, offset: 0, hasChosenStart: false)

        try write("whole\npart", to: url)
        let read = TailReader.read(url: url, offset: primed.offset, hasChosenStart: true)
        XCTAssertEqual(read.lines, ["whole"])

        try write("whole\npartial-now-complete\n", to: url)
        let next = TailReader.read(url: url, offset: read.offset, hasChosenStart: true)
        XCTAssertEqual(next.lines, ["partial-now-complete"])
    }

    /// Default policy: a per-conversation file that shrank was replaced, and the replacement
    /// is entirely ours.
    func testRestartsFromZeroWhenAReplacedFileShrinks() throws {
        let url = dir.appendingPathComponent("f.jsonl")
        try write("", to: url)
        let primed = TailReader.read(url: url, offset: 0, hasChosenStart: false)
        try write("a\nb\nc\n", to: url)
        let read = TailReader.read(url: url, offset: primed.offset, hasChosenStart: true)
        XCTAssertEqual(read.lines, ["a", "b", "c"])

        try write("z\n", to: url)
        let after = TailReader.read(url: url, offset: read.offset, hasChosenStart: true)
        XCTAssertEqual(after.lines, ["z"], "a shorter file is a new file, read from the top")
    }

    /// Index policy: a shared append-only file that shrank was COMPACTED, and its history is
    /// not ours to replay. Every replayed line would re-apply a stale value.
    func testResumesAtTheEndWhenACompactedFileShrinks() throws {
        let url = dir.appendingPathComponent("index.jsonl")
        try write("", to: url)
        let primed = TailReader.read(url: url, offset: 0, hasChosenStart: false,
                                     truncation: .resumeAtEnd)
        try write("one\ntwo\nthree\n", to: url)
        let read = TailReader.read(url: url, offset: primed.offset, hasChosenStart: true,
                                   truncation: .resumeAtEnd)
        XCTAssertEqual(read.lines, ["one", "two", "three"])

        try write("compacted\n", to: url)
        let after = TailReader.read(url: url, offset: read.offset, hasChosenStart: true,
                                    truncation: .resumeAtEnd)
        XCTAssertEqual(after.lines, [], "compaction must not replay history as fresh news")

        try write("compacted\nfresh\n", to: url)
        let next = TailReader.read(url: url, offset: after.offset, hasChosenStart: true,
                                   truncation: .resumeAtEnd)
        XCTAssertEqual(next.lines, ["fresh"], "and reading must continue from there")
    }
}
