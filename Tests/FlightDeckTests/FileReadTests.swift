import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
import FleetKit
@testable import FlightDeck

/// `file.read`: the wire shapes, and `FileReadService`'s resolution and reads against real
/// files in a temporary directory.
final class FileReadTests: XCTestCase {
    private var root: URL!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileRead-\(UUID())", isDirectory: true)
            .resolvingSymlinksInPath()
        try? FileManager.default.createDirectory(at: root.appendingPathComponent("docs"), withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value))
    }

    func testTheRequestAndItsReplyRoundTrip() throws {
        let request = FleetRequest.fileRead(session: UUID(), path: "docs/A.md", offset: 512, limit: 4096, maxPixel: 2048)
        XCTAssertEqual(try roundTrip(request), request)
        let json = String(decoding: try JSONEncoder().encode(request), as: UTF8.self)
        XCTAssertTrue(json.contains(#""op":"file.read""#), json)

        let chunk = WireFileChunk(path: "/a/b.png", size: 10, offset: 0, data: Data([1, 2, 3]),
                                  downsampled: true, pixelWidth: 4000, pixelHeight: 3000)
        let frame = ServerFrame.fileChunk(cid: 7, chunk)
        XCTAssertEqual(try roundTrip(frame), frame)
        XCTAssertEqual(frame.correlationID, 7)
        XCTAssertFalse(frame.continuesStream)
    }

    /// An older phone never sends `maxPixel`; text reads must not need it.
    func testATextReadOmitsMaxPixel() throws {
        let json = String(decoding: try JSONEncoder().encode(
            FleetRequest.fileRead(session: UUID(), path: "a.txt", offset: 0, limit: 10)), as: UTF8.self)
        XCTAssertFalse(json.contains("maxPixel"), json)
    }

    func testARelativePathResolvesAgainstEachBaseInTurn() throws {
        let worktree = root.appendingPathComponent("wt")
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        try "x".write(to: root.appendingPathComponent("docs/HANDOFF.md"), atomically: true, encoding: .utf8)

        let url = FileReadService.resolve("docs/HANDOFF.md", bases: [worktree.path, root.path])
        XCTAssertEqual(url?.path, root.appendingPathComponent("docs/HANDOFF.md").path)
    }

    func testFileURLsPercentEscapesAndAbsolutePathsResolve() throws {
        let file = root.appendingPathComponent("docs/My Notes.md")
        try "x".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(FileReadService.resolve(file.absoluteString, bases: [])?.path, file.path)
        XCTAssertEqual(FileReadService.resolve("docs/My%20Notes.md", bases: [root.path])?.path, file.path)
        XCTAssertEqual(FileReadService.resolve(file.path, bases: ["/nowhere"])?.path, file.path)
    }

    func testADirectoryOrAMissingFileIsNotFound() {
        XCTAssertNil(FileReadService.resolve("docs", bases: [root.path]))
        XCTAssertNil(FileReadService.resolve("nope.md", bases: [root.path]))
        XCTAssertNil(FileReadService.resolve("", bases: [root.path]))
    }

    func testBytesAreARangeAndTheSizeIsTheWholeFile() throws {
        let file = root.appendingPathComponent("log.txt")
        try Data("0123456789".utf8).write(to: file)
        guard case .success(let chunk) = FileReadService.bytes(at: file, offset: 4, limit: 3) else {
            return XCTFail("expected a chunk")
        }
        XCTAssertEqual(chunk.size, 10)
        XCTAssertEqual(chunk.offset, 4)
        XCTAssertEqual(String(decoding: chunk.data, as: UTF8.self), "456")
        XCTAssertFalse(chunk.isLast)

        guard case .success(let tail) = FileReadService.bytes(at: file, offset: 8, limit: 100) else {
            return XCTFail("expected a chunk")
        }
        XCTAssertEqual(String(decoding: tail.data, as: UTF8.self), "89")
        XCTAssertTrue(tail.isLast)
    }

    /// Whatever the phone asks for, one reply stays under the frame cap.
    func testALimitIsClampedToTheMaximumChunk() throws {
        let file = root.appendingPathComponent("big.log")
        try Data(count: FileLimits.maxChunk + 10).write(to: file)
        guard case .success(let chunk) = FileReadService.bytes(at: file, offset: 0, limit: .max) else {
            return XCTFail("expected a chunk")
        }
        XCTAssertEqual(chunk.data.count, FileLimits.maxChunk)
    }

    private func writePNG(width: Int, height: Int, to url: URL) throws {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }

    func testASmallImageIsSentAsItsOwnBytes() throws {
        let file = root.appendingPathComponent("small.png")
        try writePNG(width: 100, height: 50, to: file)
        guard case .success(let chunk) = FileReadService.image(at: file, maxPixel: 1000) else {
            return XCTFail("expected an image")
        }
        XCTAssertFalse(chunk.downsampled)
        XCTAssertEqual(chunk.data, try Data(contentsOf: file))
        XCTAssertEqual(chunk.pixelWidth, 100)
    }

    func testALargeImageIsDownsampledToMaxPixel() throws {
        let file = root.appendingPathComponent("large.png")
        try writePNG(width: 3000, height: 1500, to: file)
        guard case .success(let chunk) = FileReadService.image(at: file, maxPixel: 600) else {
            return XCTFail("expected an image")
        }
        XCTAssertTrue(chunk.downsampled)
        XCTAssertEqual(chunk.pixelWidth, 3000)
        XCTAssertEqual(chunk.pixelHeight, 1500)
        let source = CGImageSourceCreateWithData(chunk.data as CFData, nil)!
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as! [CFString: Any]
        XCTAssertEqual(props[kCGImagePropertyPixelWidth] as? Int, 600)
        XCTAssertEqual(props[kCGImagePropertyPixelHeight] as? Int, 300)
        XCTAssertEqual(CGImageSourceGetType(source) as String?, UTType.jpeg.identifier)
    }

    func testATextFileAskedForAsAnImageIsRefused() throws {
        let file = root.appendingPathComponent("fake.png")
        try Data("not an image".utf8).write(to: file)
        guard case .failure(let code) = FileReadService.image(at: file, maxPixel: 100) else {
            return XCTFail("expected a refusal")
        }
        XCTAssertEqual(code, "not_an_image")
    }
}
