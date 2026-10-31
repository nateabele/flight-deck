import FleetKit
import XCTest
@testable import FlightDeckMobile

/// The phone's fetch of a revision's files (P2a V3): chunked, hash-checked, cached by revision.
@MainActor
final class VisualLoaderTests: XCTestCase {
    private var dir: URL!
    private let intake = UUID()

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("VisualLoader-\(UUID())", isDirectory: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    private func wire(_ path: String, _ data: Data, lie: Bool = false) -> WireVisualFile {
        WireVisualFile(path: path, size: Int64(data.count), sha256: lie ? String(repeating: "0", count: 64) : VisualCache.sha256Hex(data))
    }

    func testFetchesInChunksChecksTheHashAndCaches() async {
        let bytes = Data((0..<10).map { UInt8($0) })
        let fetcher = FakeFetcher(files: ["export/index.html": bytes], chunk: 4)
        let loader = VisualLoader(fetcher: fetcher, cache: VisualCache(directory: dir, budget: 1_000), chunkSize: 4)
        let got = await loader.data(intake: intake, visualID: "flow", revision: 1, file: wire("export/index.html", bytes))
        XCTAssertEqual(got, bytes)
        XCTAssertEqual(fetcher.requests.map(\.offset), [0, 4, 8])
        XCTAssertEqual(fetcher.requests.map(\.part), Array(repeating: "file:export/index.html", count: 3))
        // Second time: from the cache, no request.
        let again = await loader.data(intake: intake, visualID: "flow", revision: 1, file: wire("export/index.html", bytes))
        XCTAssertEqual(again, bytes)
        XCTAssertEqual(fetcher.requests.count, 3)
    }

    func testABadHashIsNotCachedAndNotReturned() async {
        let bytes = Data("tampered".utf8)
        let fetcher = FakeFetcher(files: ["export/index.html": bytes], chunk: 100)
        let cache = VisualCache(directory: dir, budget: 1_000)
        let loader = VisualLoader(fetcher: fetcher, cache: cache, chunkSize: 100)
        let got = await loader.data(intake: intake, visualID: "flow", revision: 1, file: wire("export/index.html", bytes, lie: true))
        XCTAssertNil(got)
        XCTAssertEqual(cache.totalBytes(), 0)
    }

    func testARefusalOrAShortFileGivesNothing() async {
        let bytes = Data("abc".utf8)
        let fetcher = FakeFetcher(files: [:], chunk: 100)
        let loader = VisualLoader(fetcher: fetcher, cache: VisualCache(directory: dir, budget: 1_000), chunkSize: 100)
        let refused = await loader.data(intake: intake, visualID: "flow", revision: 1, file: wire("export/index.html", bytes))
        XCTAssertNil(refused)
        // The manifest says 5 bytes and the Mac sends 3.
        let lying = WireVisualFile(path: "export/index.html", size: 5, sha256: VisualCache.sha256Hex(bytes))
        let fetcher2 = FakeFetcher(files: ["export/index.html": bytes], chunk: 100)
        let loader2 = VisualLoader(fetcher: fetcher2, cache: VisualCache(directory: dir, budget: 1_000), chunkSize: 100)
        let short = await loader2.data(intake: intake, visualID: "flow", revision: 1, file: lying)
        XCTAssertNil(short)
    }

    func testASnapshotAsksForItsStateAndSize() async {
        let png = Data([1, 2, 3])
        let fetcher = FakeFetcher(files: ["snapshot@checkout-narrow.png": png], chunk: 100)
        let loader = VisualLoader(fetcher: fetcher, cache: VisualCache(directory: dir, budget: 1_000), chunkSize: 100)
        let ref = WireVisualRef(id: "flow", revision: 3, states: ["default", "checkout"], sizes: ["wide", "narrow"],
                                files: [wire("snapshot@checkout-narrow.png", png)])
        let got = await loader.snapshot(intake: intake, ref: ref, state: "checkout", size: "narrow")
        XCTAssertEqual(got, png)
        XCTAssertEqual(fetcher.requests.first?.part, "snapshot@checkout-narrow")
        XCTAssertEqual(fetcher.requests.first?.revision, 3)
        // A snapshot the ref's file list does not carry cannot be checked, so it is not fetched.
        let none = await loader.snapshot(intake: intake, ref: ref, state: "ghost", size: "narrow")
        XCTAssertNil(none)
        XCTAssertEqual(fetcher.requests.count, 1)
    }

    func testEnsureAllFetchesEveryListedFileOnce() async {
        let a = Data("a".utf8), b = Data("bb".utf8)
        let fetcher = FakeFetcher(files: ["export/a.html": a, "export/b.css": b], chunk: 100)
        let loader = VisualLoader(fetcher: fetcher, cache: VisualCache(directory: dir, budget: 1_000), chunkSize: 100)
        let ref = WireVisualRef(id: "flow", revision: 1, files: [wire("export/a.html", a), wire("export/b.css", b)])
        let ok = await loader.ensureAll(intake: intake, ref: ref)
        XCTAssertTrue(ok)
        XCTAssertEqual(Set(fetcher.requests.map(\.part)), ["file:export/a.html", "file:export/b.css"])
        let fail = await loader.ensureAll(intake: intake, ref: WireVisualRef(id: "flow", revision: 1, files: nil))
        XCTAssertFalse(fail, "no file list, nothing to check against")
    }
}

@MainActor
private final class FakeFetcher: VisualFetching {
    struct Request { var part: String; var offset: Int64; var revision: Int }
    var requests: [Request] = []
    private let files: [String: Data]
    private let chunk: Int
    init(files: [String: Data], chunk: Int) { self.files = files; self.chunk = chunk }

    func fetchVisual(intake: UUID, visualID: String, revision: Int, part: String, offset: Int64, limit: Int,
                     then completion: @escaping (Result<WireFileChunk, FleetRequestError>) -> Void) {
        requests.append(Request(part: part, offset: offset, revision: revision))
        let path = WireVisualPart.filePath(in: part) ?? (part.hasPrefix("snapshot@") ? part + ".png" : "")
        guard let bytes = files[path] else { return completion(.failure(.server(code: "unknown_file"))) }
        let start = Int(offset)
        let end = min(bytes.count, start + min(chunk, limit))
        completion(.success(WireFileChunk(path: path, size: Int64(bytes.count), offset: offset, data: bytes.subdata(in: start..<end))))
    }
}
