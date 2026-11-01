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

    // MARK: - Review 1

    private func loader(_ fetcher: FakeFetcher, budget: Int64 = 1_000_000, chunk: Int = 100,
                        deadline: Duration = .seconds(15)) -> VisualLoader {
        VisualLoader(fetcher: fetcher, cache: VisualCache(directory: dir, budget: budget), chunkSize: chunk, chunkDeadline: deadline)
    }

    func testARefWithNoFilesTooManyFilesNegativeOrOverCapSizesIsRefusedBeforeAnyRequest() async {
        let fetcher = FakeFetcher(files: [:], chunk: 100)
        let l = loader(fetcher)
        let ok = WireVisualFile(path: "a", size: 1, sha256: "")
        let many = (0..<65).map { WireVisualFile(path: "f\($0)", size: 1, sha256: "") }
        let half = Int64(VisualLimits.maxBytes / 2 + 1)
        let cases: [(String, [WireVisualFile]?)] = [
            ("nil", nil), ("empty", []), ("65 files", many),
            ("negative", [ok, WireVisualFile(path: "b", size: -1, sha256: "")]),
            ("over cap", [WireVisualFile(path: "a", size: half, sha256: ""), WireVisualFile(path: "b", size: half, sha256: "")]),
            ("overflow", [WireVisualFile(path: "a", size: Int64.max, sha256: ""), WireVisualFile(path: "b", size: Int64.max, sha256: "")]),
        ]
        for (name, files) in cases {
            let ref = WireVisualRef(id: "flow", revision: 1, states: ["s"], sizes: ["narrow"], files: files)
            let all = await l.ensureAll(intake: intake, ref: ref)
            XCTAssertFalse(all, name)
            let snap = await l.snapshot(intake: intake, ref: ref, state: nil, size: nil)
            XCTAssertNil(snap, name)
        }
        XCTAssertTrue(fetcher.requests.isEmpty)
    }

    /// The cache evicts its own revision's earlier file to fit the later one; success is not
    /// claimed for a file that is gone.
    func testEnsureAllFailsWhenTheCacheHasEvictedAFileOfTheRevision() async {
        let a = Data("aa".utf8), b = Data("bb".utf8)
        let fetcher = FakeFetcher(files: ["export/a.html": a, "export/b.css": b], chunk: 100)
        let l = loader(fetcher, budget: 3)
        let ref = WireVisualRef(id: "flow", revision: 1, files: [wire("export/a.html", a), wire("export/b.css", b)])
        let ok = await l.ensureAll(intake: intake, ref: ref)
        XCTAssertFalse(ok)
    }

    func testAFileOverTheCapIsNotFetched() async {
        let big = WireVisualFile(path: "export/big.bin", size: Int64(VisualLimits.maxBytes) + 1, sha256: String(repeating: "a", count: 64))
        let fetcher = FakeFetcher(files: ["export/big.bin": Data(count: 10)], chunk: 100)
        let got = await loader(fetcher).data(intake: intake, visualID: "flow", revision: 1, file: big)
        XCTAssertNil(got)
        XCTAssertTrue(fetcher.requests.isEmpty)
    }

    func testAChunkLongerThanAskedOrForAnotherPathIsRefused() async {
        let bytes = Data("0123456789".utf8)
        let long = FakeFetcher(files: ["export/a.html": bytes], chunk: 100)
        long.overLength = true
        let l1 = loader(long, chunk: 4)
        let g1 = await l1.data(intake: intake, visualID: "flow", revision: 1, file: wire("export/a.html", bytes))
        XCTAssertNil(g1, "10 bytes came back for a limit of 4")
        let other = FakeFetcher(files: ["export/a.html": bytes], chunk: 100)
        other.pathOverride = "export/other.html"
        let g2 = await loader(other).data(intake: intake, visualID: "flow", revision: 1, file: wire("export/a.html", bytes))
        XCTAssertNil(g2)
    }

    func testAMacThatNeverAnswersTimesOutAndRetryStartsFresh() async {
        let bytes = Data("hello".utf8)
        let fetcher = FakeFetcher(files: ["export/a.html": bytes], chunk: 100)
        fetcher.silent = true
        let l = loader(fetcher, deadline: .milliseconds(50))
        let file = wire("export/a.html", bytes)
        let first = await l.data(intake: intake, visualID: "flow", revision: 1, file: file)
        XCTAssertNil(first)
        fetcher.silent = false
        let retry = await l.data(intake: intake, visualID: "flow", revision: 1, file: file)
        XCTAssertEqual(retry, bytes)
        XCTAssertEqual(fetcher.requests.count, 2, "the retry made its own request, not joining the dead one")
    }

    /// V3 review 1, parked: the timed-out request was still registered with the connector, so a
    /// Mac that never answered left a handler there until the socket closed.
    func testATimedOutChunkIsCancelledSoItsHandlerIsUnregistered() async {
        let bytes = Data("hello".utf8)
        let fetcher = FakeFetcher(files: ["export/a.html": bytes], chunk: 100)
        fetcher.silent = true
        let l = loader(fetcher, deadline: .milliseconds(50))
        let got = await l.data(intake: intake, visualID: "flow", revision: 1, file: wire("export/a.html", bytes))
        XCTAssertNil(got)
        XCTAssertEqual(fetcher.cancelled, 1)
        // A request that is answered is not cancelled afterwards.
        fetcher.silent = false
        _ = await l.data(intake: intake, visualID: "flow", revision: 1, file: wire("export/a.html", bytes))
        XCTAssertEqual(fetcher.cancelled, 1)
    }

    /// The Mac draws every state at the first size, and the first state at the others
    /// (`VisualSnapshotPlan`), so a phone-sized picture of a later state does not exist.
    func testASnapshotOfALaterStateFallsBackToTheSizeTheMacDrewIt() async {
        let idlePhone = Data([1]), failedWide = Data([2]), idleWide = Data([3])
        let fetcher = FakeFetcher(files: ["snapshot@idle-phone.png": idlePhone, "snapshot@failed-wide.png": failedWide,
                                          "snapshot@idle-wide.png": idleWide], chunk: 100)
        let l = loader(fetcher)
        let ref = WireVisualRef(id: "flow", revision: 1, states: ["idle", "failed"], sizes: ["wide", "phone"],
                                files: [wire("snapshot@idle-wide.png", idleWide), wire("snapshot@failed-wide.png", failedWide),
                                        wire("snapshot@idle-phone.png", idlePhone)])
        let exact = await l.snapshot(intake: intake, ref: ref, state: "idle", size: "phone")
        XCTAssertEqual(exact, idlePhone)
        let fallback = await l.snapshot(intake: intake, ref: ref, state: "failed", size: "phone")
        XCTAssertEqual(fallback, failedWide, "failed was only drawn at the first size")
        XCTAssertEqual(fetcher.requests.last?.part, "snapshot@failed-wide")
        let none = await l.snapshot(intake: intake, ref: ref, state: "ghost", size: "phone")
        XCTAssertNil(none, "a state with no picture at any size")
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
    var silent = false
    var overLength = false
    var pathOverride: String?
    init(files: [String: Data], chunk: Int) { self.files = files; self.chunk = chunk }

    /// How many requests were abandoned (the loader gave up and said so).
    var cancelled = 0

    func fetchVisual(intake: UUID, visualID: String, revision: Int, part: String, offset: Int64, limit: Int,
                     then completion: @escaping (Result<WireFileChunk, FleetRequestError>) -> Void) -> () -> Void {
        requests.append(Request(part: part, offset: offset, revision: revision))
        let cancel: () -> Void = { [weak self] in self?.cancelled += 1 }
        let path = WireVisualPart.filePath(in: part) ?? (part.hasPrefix("snapshot@") ? part + ".png" : "")
        if silent { return cancel }
        guard let bytes = files[path] else { completion(.failure(.server(code: "unknown_file"))); return cancel }
        let start = Int(offset)
        let end = overLength ? bytes.count : min(bytes.count, start + min(chunk, limit))
        completion(.success(WireFileChunk(path: pathOverride ?? path, size: Int64(bytes.count), offset: offset, data: bytes.subdata(in: start..<end))))
        return cancel
    }
}
