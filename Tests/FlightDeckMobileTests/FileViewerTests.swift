import FleetKit
import XCTest
@testable import FlightDeckMobile

/// Which links open in-app, and how the viewer buffers a file it reads in pieces. Logic only —
/// the screen itself is on docs/MOBILE.md's checklist.
@MainActor
final class FileViewerTests: XCTestCase {

    // MARK: Links

    private func link(_ string: String) -> LocalFileLink? {
        URL(string: string).flatMap(LocalFileLink.init)
    }

    func testTheShapesAgentsWriteAreFileLinks() {
        XCTAssertEqual(link("docs/HANDOFF.md")?.path, "docs/HANDOFF.md")
        XCTAssertEqual(link("docs/HANDOFF.md")?.kind, .markdown)
        XCTAssertEqual(link("/Users/me/plan.md")?.path, "/Users/me/plan.md")
        XCTAssertEqual(link("file:///Users/me/a.log")?.path, "/Users/me/a.log")
        XCTAssertEqual(link("file:///Users/me/a.log")?.kind, .text(code: false))
        XCTAssertEqual(link("../shot.PNG")?.kind, .image)
        XCTAssertEqual(link("docs/My%20Notes.md")?.path, "docs/My Notes.md")
        XCTAssertEqual(LocalFileLink(string: "~/notes.txt")?.path, "~/notes.txt")
    }

    func testALineSuffixIsSplitOff() {
        let colon = link("Sources/Foo.swift:42")
        XCTAssertEqual(colon?.path, "Sources/Foo.swift")
        XCTAssertEqual(colon?.line, 42)
        XCTAssertEqual(colon?.kind, .text(code: true))
        XCTAssertEqual(link("Foo.swift:42:7")?.line, 42)
        XCTAssertEqual(link("Foo.swift:42:7")?.path, "Foo.swift")
        XCTAssertEqual(link("Sources/Foo.swift#L12-L20")?.line, 12)
        XCTAssertEqual(link("Sources/Foo.swift#L12-L20")?.path, "Sources/Foo.swift")
    }

    /// Everything else keeps the system's handling, which is how it behaved before.
    func testWebLinksDirectoriesAndUnknownTypesAreNot() {
        XCTAssertNil(link("https://example.com/readme.md"))
        XCTAssertNil(link("mailto:a@b.c"))
        XCTAssertNil(link("localhost:8080"))
        XCTAssertNil(link("docs/superpowers/specs"))
        XCTAssertNil(link("docs/"))
        XCTAssertNil(link("build/app.zip"))
        XCTAssertNil(link("#section"))
    }

    func testWellKnownNamesWithoutAnExtensionAreText() {
        XCTAssertEqual(link("Makefile")?.kind, .text(code: true))
        XCTAssertEqual(link("LICENSE")?.kind, .text(code: false))
        XCTAssertEqual(link(".gitignore")?.kind, .text(code: true))
    }

    /// A markdown file's own relative links mean its folder.
    func testARelativeLinkResolvesAgainstTheViewedFilesFolder() {
        let resolved = link("../ARCHITECTURE.md")!.resolved(against: "/repo/docs/sub")
        XCTAssertEqual(resolved.path, "/repo/docs/ARCHITECTURE.md")
        XCTAssertEqual(link("/abs.md")!.resolved(against: "/repo").path, "/abs.md")
        XCTAssertEqual(link("a.md")!.resolved(against: nil).path, "a.md")
    }

    // MARK: Buffering

    /// Serves `content` in `chunk`-byte pieces, as the Mac does, and records each request.
    private final class FakeReader: FileReading {
        var content: Data
        var chunk: Int
        var error: FleetRequestError?
        var requests: [(offset: Int64, maxPixel: Int?)] = []
        var hold = false
        var held: [() -> Void] = []

        init(_ content: Data, chunk: Int) { self.content = content; self.chunk = chunk }

        func readFile(session: UUID, path: String, offset: Int64, limit: Int, maxPixel: Int?,
                      then completion: @escaping (Result<WireFileChunk, FleetRequestError>) -> Void) {
            requests.append((offset, maxPixel))
            if let error { return completion(.failure(error)) }
            let start = Int(offset)
            let end = min(content.count, start + chunk)
            let reply = WireFileChunk(path: "/repo/" + path, size: Int64(content.count), offset: offset,
                                      data: content.subdata(in: start..<end))
            if hold { held.append { completion(.success(reply)) } } else { completion(.success(reply)) }
        }
    }

    private func model(_ path: String, _ text: String, chunk: Int = 1_000_000) -> (FileViewerModel, FakeReader) {
        let reader = FakeReader(Data(text.utf8), chunk: chunk)
        let link = LocalFileLink(string: path)!
        return (FileViewerModel(route: FileRoute(session: UUID(), link: link), reader: reader), reader)
    }

    /// Reads to the end, failing rather than spinning when a read stops making progress.
    private func drain(_ model: FileViewerModel, file: StaticString = #filePath, line: UInt = #line) {
        for _ in 0..<1_000 where !model.isComplete {
            let before = model.loaded
            model.loadMore()
            if model.loaded == before { return XCTFail("stalled at \(before) in \(model.phase)", file: file, line: line) }
        }
    }

    func testAShortTextFileLoadsWholeInLines() {
        let (model, reader) = model("a.txt", "one\ntwo\nthree\n")
        model.start()
        XCTAssertEqual(model.phase, .loaded)
        XCTAssertEqual(model.groups, ["one\ntwo\nthree"])
        XCTAssertEqual(model.lineCount, 3)
        XCTAssertEqual(model.resolvedPath, "/repo/a.txt")
        XCTAssertNil(reader.requests.first?.maxPixel)
        XCTAssertTrue(model.isComplete)
    }

    func testTheNextChunkIsAskedForOnlyWhenTheReaderReachesTheEnd() {
        let lines = (1...100).map { "line \($0)" }.joined(separator: "\n")
        let (model, reader) = model("a.log", lines, chunk: 64)
        model.start()
        XCTAssertEqual(reader.requests.count, 1)
        XCTAssertFalse(model.isComplete)
        drain(model)
        XCTAssertEqual(model.lineCount, 100)
        XCTAssertEqual(model.groups.count, 3)
        XCTAssertEqual(model.groups.joined(separator: "\n"), lines)
        XCTAssertEqual(reader.requests.map(\.offset), stride(from: 0, to: Int64(lines.utf8.count), by: 64).map { $0 })
    }

    func testAMultibyteCharacterSplitAcrossChunksSurvives() {
        // "é" is two bytes and "🛫" four; a 3-byte chunk splits both.
        let text = "aé🛫b\nz"
        let (model, _) = model("a.txt", text, chunk: 3)
        model.start()
        drain(model)
        XCTAssertEqual(model.groups.joined(separator: "\n"), text)
    }

    func testCompleteUTF8Prefix() {
        XCTAssertEqual(FileViewerModel.completeUTF8Prefix(Data("ab".utf8)), 2)
        let emoji = Data("a🛫".utf8)  // 1 + 4 bytes
        XCTAssertEqual(FileViewerModel.completeUTF8Prefix(emoji), 5)
        XCTAssertEqual(FileViewerModel.completeUTF8Prefix(emoji.prefix(3)), 1)
        XCTAssertEqual(FileViewerModel.completeUTF8Prefix(emoji.prefix(1)), 1)
    }

    func testCRLFLinesSplit() {
        let (model, _) = model("a.txt", "one\r\ntwo\r\n", chunk: 4)
        model.start()
        drain(model)
        XCTAssertEqual(model.groups, ["one\ntwo"])
    }

    /// The block a chunk boundary may cut is held back until the rest of it arrives.
    func testMarkdownHoldsBackItsLastBlockUntilTheEnd() {
        let text = "# Title\n\nFirst paragraph.\n\n```swift\nlet a = 1\n```\n"
        let (model, _) = model("a.md", text, chunk: 30)
        model.start()
        XCTAssertEqual(model.blocks.map(\.text), ["# Title", "First paragraph."])
        drain(model)
        XCTAssertEqual(model.blocks.map(\.text), PlanBlocks.split(text).blocks.map(\.text))
    }

    func testFrontMatterBecomesAFence() {
        XCTAssertEqual(FileViewerModel.fencingFrontMatter("---\nname: x\n---\n# Hi"),
                       "```yaml\nname: x\n```\n# Hi")
        XCTAssertEqual(FileViewerModel.fencingFrontMatter("# Hi\n---\n"), "# Hi\n---\n")
    }

    func testABinaryFileIsRefused() {
        let reader = FakeReader(Data([0x89, 0x00, 0x01]), chunk: 100)
        let model = FileViewerModel(route: FileRoute(session: UUID(), link: LocalFileLink(string: "a.txt")!), reader: reader)
        model.start()
        XCTAssertEqual(model.phase, .failed("This file isn't text."))
    }

    /// A link to line 90 of a file whose first chunk holds 20 lines keeps reading toward it.
    func testALinkedLineIsReadToward() {
        let lines = (1...100).map { "line \($0)" }.joined(separator: "\n")
        let (model, _) = model("a.swift:90", lines, chunk: 128)
        model.start()
        XCTAssertGreaterThanOrEqual(model.lineCount, 90)
    }

    func testAFailureSaysWhyInWordsAboutTheFile() {
        let (model, reader) = model("docs/A.md", "x")
        reader.error = .server(code: "not_found")
        model.start()
        XCTAssertEqual(model.phase, .failed("Couldn't find docs/A.md on your Mac."))
        XCTAssertEqual(FileViewerModel.message(for: .server(code: "unsupported"), path: "a"),
                       "Update Flight Deck on your Mac to open files from the phone.")
    }

    /// A failed later chunk keeps what is on screen and offers a retry.
    func testALaterFailureKeepsWhatIsShown() {
        let (model, reader) = model("a.txt", String(repeating: "x\n", count: 100), chunk: 50)
        model.start()
        reader.error = .disconnected
        model.loadMore()
        XCTAssertEqual(model.phase, .loaded)
        XCTAssertTrue(model.moreFailed)
        XCTAssertFalse(model.groups.isEmpty)
    }

    func testAnImageAsksForTheScreensPixels() {
        let reader = FakeReader(Data(), chunk: 1)
        reader.error = .disconnected
        let model = FileViewerModel(route: FileRoute(session: UUID(), link: LocalFileLink(string: "a.png")!),
                                    reader: reader, maxPixel: 1234)
        model.start()
        XCTAssertEqual(reader.requests.first?.maxPixel, 1234)
    }

    func testTheGutterHoldsThreeDigitsUntilTheFileNeedsMore() {
        XCTAssertEqual(FileTextStyle.gutterDigits(lineCount: 0), 3)
        XCTAssertEqual(FileTextStyle.gutterDigits(lineCount: 999), 3)
        XCTAssertEqual(FileTextStyle.gutterDigits(lineCount: 1_000), 4)
        XCTAssertEqual(FileTextStyle.gutterDigits(lineCount: 123_456), 6)
        XCTAssertGreaterThan(FileTextStyle.gutterWidth(digits: 4), FileTextStyle.gutterWidth(digits: 3))
    }

    func testTheHighlightLandsOnTheLinkedLine() {
        let attributed = FileTextStyle.attributed("a\nbb\nccc", firstLine: 40, highlight: 41)
        let washed = attributed.runs.filter { $0.backgroundColor != nil }.map { String(attributed[$0.range].characters) }
        XCTAssertEqual(washed, ["bb"])
        XCTAssertTrue(FileTextStyle.attributed("a", firstLine: 0, highlight: 41).runs.allSatisfy { $0.backgroundColor == nil })
    }
}
