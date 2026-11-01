import XCTest
import FleetKit
import IntakeKit
@testable import FlightDeck

/// `VisualFetch.serve` (P2a V3): `intake.visual.fetch` answered from a revision's listed files,
/// in chunks. It reads only through `VisualStoreReading.read`, so these run it over the real
/// `DiskVisualStore` (confinement is proven in `DiskVisualStoreTests`; here it is the mapping,
/// the chunking, the refusals and the thread).
final class VisualFetchTests: XCTestCase {
    private var root: URL!
    private let id = VisualID(rawValue: "flow")!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("VisualFetch-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    private var tape: TapeStore { TapeStore(intakeDirectory: root) }
    private var store: DiskVisualStore { DiskVisualStore(intakeDirectory: root) }

    /// A revision with these files (path to bytes), all listed in its manifest.
    @discardableResult
    private func install(r: Int = 1, files: [String: Data], unlisted: [String: Data] = [:],
                         states: [String] = ["default"], sizes: [String] = ["wide"]) throws -> URL {
        let dir = tape.revisionDirectory(id, r: r)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (name, data) in files.merging(unlisted, uniquingKeysWith: { a, _ in a }) {
            let url = dir.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }
        let manifest = VisualManifest(
            provider: "canvas", providerVersion: "1", kind: "comp", title: "T", entry: "export/index.html",
            states: states, sizes: sizes, madeOnCheckpoint: 1, madeBy: .you, primary: true,
            files: files.sorted { $0.key < $1.key }.map { VisualFileEntry(path: $0.key, size: Int64($0.value.count), sha256: "") })
        try IntakeJSON.encoder.encode(manifest).write(to: dir.appendingPathComponent("manifest.json"))
        return dir
    }

    private func serve(_ part: String, offset: Int64 = 0, limit: Int = 1 << 20, r: Int = 1, visual: String = "flow",
                       reader: (any VisualStoreReading)? = nil, open: Bool = true) async -> Result<WireFileChunk, VisualRefusal> {
        await VisualFetch.serve(reader ?? store, visualID: visual, revision: r, part: part, offset: offset, limit: limit,
                                gateOpen: open)
    }

    private func code(_ result: Result<WireFileChunk, VisualRefusal>) -> String? {
        if case .failure(let r) = result { return r.code }
        return nil
    }

    // MARK: - Mapping

    func testAFilePartServesThatFileWithItsRelativePathAndSize() async throws {
        try install(files: ["export/index.html": Data("<p>hi</p>".utf8), "snapshot@default-wide.png": Data([1, 2, 3])])
        let chunk = try await serve(WireVisualPart.file("export/index.html")).get()
        XCTAssertEqual(chunk.path, "export/index.html")
        XCTAssertEqual(chunk.data, Data("<p>hi</p>".utf8))
        XCTAssertEqual(chunk.size, 9)
        XCTAssertEqual(chunk.offset, 0)
        XCTAssertTrue(chunk.isLast)
    }

    func testASnapshotPartNamesTheStateAndSize() async throws {
        try install(files: ["snapshot@checkout-narrow.png": Data([9, 9]), "snapshot@default-wide.png": Data([1])],
                    states: ["default", "checkout"], sizes: ["wide", "narrow"])
        let named = try await serve(WireVisualPart.snapshot(state: "checkout", size: "narrow")).get()
        XCTAssertEqual(named.data, Data([9, 9]))
        XCTAssertEqual(named.path, "snapshot@checkout-narrow.png")
    }

    func testPlainSnapshotIsTheFirstStateAtTheFirstSize() async throws {
        try install(files: ["snapshot@checkout-narrow.png": Data([9]), "snapshot@default-wide.png": Data([1])],
                    states: ["default", "checkout"], sizes: ["wide", "narrow"])
        let chunk = try await serve(WireVisualPart.snapshot).get()
        XCTAssertEqual(chunk.path, "snapshot@default-wide.png")
    }

    // MARK: - Chunking

    func testAFileComesInChunksThatAddUpToTheFile() async throws {
        let bytes = Data((0..<1000).map { UInt8($0 % 251) })
        try install(files: ["export/a.js": bytes])
        var got = Data()
        var offset: Int64 = 0
        var chunks = 0
        while true {
            let chunk = try await serve(WireVisualPart.file("export/a.js"), offset: offset, limit: 300).get()
            XCTAssertEqual(chunk.size, 1000)
            XCTAssertEqual(chunk.offset, offset)
            XCTAssertLessThanOrEqual(chunk.data.count, 300)
            got.append(chunk.data)
            offset += Int64(chunk.data.count)
            chunks += 1
            if chunk.isLast { break }
        }
        XCTAssertEqual(got, bytes)
        XCTAssertEqual(chunks, 4)
    }

    func testALimitAboveTheWireCapIsCapped() async throws {
        let bytes = Data(count: FileLimits.maxChunk + 10)
        try install(files: ["export/big.bin": bytes])
        let chunk = try await serve(WireVisualPart.file("export/big.bin"), limit: Int.max).get()
        XCTAssertEqual(chunk.data.count, FileLimits.maxChunk)
        XCTAssertFalse(chunk.isLast)
    }

    func testAnOffsetAtTheEndIsAnEmptyLastChunk() async throws {
        try install(files: ["export/a.js": Data("ab".utf8)])
        let chunk = try await serve(WireVisualPart.file("export/a.js"), offset: 2).get()
        XCTAssertTrue(chunk.data.isEmpty)
        XCTAssertTrue(chunk.isLast)
    }

    // MARK: - Refusals

    func testARevisionOverTheCapIsTooLarge() async throws {
        // Two files that fit alone and not together: the cap is on the revision, as the wire says.
        let half = Data(count: VisualLimits.maxBytes / 2 + 1)
        try install(files: ["export/a.bin": half, "export/b.bin": half])
        let a = await serve(WireVisualPart.file("export/a.bin"))
        XCTAssertEqual(code(a), "too_large")
    }

    func testARevisionExactlyAtTheCapIsServed() async throws {
        let half = Data(count: VisualLimits.maxBytes / 2)
        try install(files: ["export/a.bin": half, "export/b.bin": half])
        let chunk = try await serve(WireVisualPart.file("export/a.bin"), limit: 10).get()
        XCTAssertEqual(chunk.data.count, 10)
    }

    /// A hostile local manifest: sizes that overflow a sum (a trap with `reduce`) or are negative.
    func testAnOverflowingOrNegativeManifestIsRefusedNotTrapped() async throws {
        let dir = tape.revisionDirectory(id, r: 1)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        func manifest(_ sizes: [Int64]) throws {
            let m = VisualManifest(provider: "p", providerVersion: "1", kind: "k", title: "T", entry: "a", madeOnCheckpoint: 1, madeBy: .you,
                                   files: sizes.enumerated().map { VisualFileEntry(path: "f\($0.offset)", size: $0.element, sha256: "") })
            try IntakeJSON.encoder.encode(m).write(to: dir.appendingPathComponent("manifest.json"))
        }
        try manifest([Int64.max, Int64.max])
        let over = await serve("file:f0")
        XCTAssertEqual(code(over), "too_large")
        try manifest([5, -1])
        let neg = await serve("file:f0")
        XCTAssertEqual(code(neg), "bad_manifest")
    }

    func testRefusals() async throws {
        try install(files: ["export/index.html": Data("x".utf8)], unlisted: ["export/secret.txt": Data("s".utf8)])
        let listed = WireVisualPart.file("export/index.html")
        let cases: [(String, Result<WireFileChunk, VisualRefusal>)] = [
            ("unknown_visual", await serve(listed, visual: "nope")),
            ("unknown_visual", await serve(listed, visual: "../etc")),
            ("unknown_revision", await serve(listed, r: 9)),
            ("bad_part", await serve("bundle")),
            ("bad_part", await serve("file:")),
            ("bad_part", await serve("snapshot@")),
            ("unknown_file", await serve(WireVisualPart.file("export/secret.txt"))),
            ("unknown_file", await serve(WireVisualPart.file("manifest.json"))),
            ("unknown_file", await serve(WireVisualPart.file("../flow/r1/export/index.html"))),
            ("unknown_file", await serve(WireVisualPart.file("/etc/passwd"))),
            ("unknown_file", await serve(WireVisualPart.snapshot(state: "ghost", size: "wide"))),
            ("bad_range", await serve(listed, offset: -1)),
            ("bad_range", await serve(listed, limit: 0)),
            ("bad_range", await serve(listed, offset: 99)),
        ]
        for (want, got) in cases { XCTAssertEqual(code(got), want, "\(got)") }
    }

    /// A file the manifest lists that is gone from disk, or is a symlink out of the folder: the
    /// store returns nil and the worker refuses rather than guessing why.
    func testAnythingTheStoreWillNotReadIsRefused() async throws {
        let dir = try install(files: ["export/a.txt": Data("a".utf8), "export/link.txt": Data("l".utf8)])
        try FileManager.default.removeItem(at: dir.appendingPathComponent("export/a.txt"))
        let outside = root.appendingPathComponent("outside.txt")
        try Data("o".utf8).write(to: outside)
        try FileManager.default.removeItem(at: dir.appendingPathComponent("export/link.txt"))
        try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("export/link.txt"), withDestinationURL: outside)
        let gone = await serve(WireVisualPart.file("export/a.txt"))
        let link = await serve(WireVisualPart.file("export/link.txt"))
        XCTAssertEqual(code(gone), "unreadable")
        XCTAssertEqual(code(link), "unreadable")
    }

    func testNoReaderOrAClosedGateIsUnavailable() async throws {
        try install(files: ["export/a.txt": Data("a".utf8)])
        let none = await VisualFetch.serve(nil, visualID: "flow", revision: 1, part: "file:export/a.txt",
                                           offset: 0, limit: 10, gateOpen: true)
        XCTAssertEqual(code(none), "visuals_unavailable")
        // The gate stays closed until V4: with it shut, a fully valid request is still refused,
        // and the store is never touched.
        let shut = await serve(WireVisualPart.file("export/a.txt"), open: false)
        XCTAssertEqual(code(shut), "visuals_unavailable")
        let byDefault = await VisualFetch.serve(store, visualID: "flow", revision: 1, part: "file:export/a.txt",
                                                offset: 0, limit: 10)
        XCTAssertEqual(code(byDefault), "visuals_unavailable", "the shipped default is closed")
        XCTAssertFalse(VisualFetch.gateOpen)
    }

    // MARK: - Threads

    /// The worker, and every read it makes, run off the main thread: a 10 MB read and hash on
    /// the main actor would hitch the UI (`VisualFetch`'s own doc comment).
    func testTheWorkAndTheReadHappenOffTheMainThread() async throws {
        try install(files: ["export/a.txt": Data("a".utf8)])
        let spy = SpyStore(wrapping: store)
        nonisolated(unsafe) var probeOnMain: Bool?
        let result = await VisualFetch.serve(spy, visualID: "flow", revision: 1, part: "file:export/a.txt", offset: 0, limit: 10,
                                             gateOpen: true, probe: { probeOnMain = Thread.isMainThread })
        XCTAssertNoThrow(try result.get())
        XCTAssertEqual(probeOnMain, false)
        XCTAssertEqual(spy.reads(), 1)
        XCTAssertEqual(spy.readOnMain(), false)
    }

    /// Called from the main actor, a fetch still does not hold it: the main run loop turns
    /// while a slow read is in progress.
    func testASlowReadDoesNotBlockTheMainActor() async throws {
        try install(files: ["export/a.txt": Data("a".utf8)])
        let spy = SpyStore(wrapping: store, delay: 0.3)
        let ticks = await MainActor.run { TickCounter() }
        await MainActor.run { ticks.start() }
        _ = await VisualFetch.serve(spy, visualID: "flow", revision: 1, part: "file:export/a.txt", offset: 0, limit: 10,
                                    gateOpen: true)
        let n = await MainActor.run { ticks.stop() }
        XCTAssertGreaterThan(n, 3, "the main actor kept turning during a 0.3 s read")
    }
}

/// Counts main-queue turns at 10 ms apart.
@MainActor
private final class TickCounter {
    private var timer: Timer?
    private var count = 0
    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.01, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.count += 1 }
        }
    }
    func stop() -> Int { timer?.invalidate(); return count }
}

/// Records where `read` ran; everything else passes through.
private final class SpyStore: VisualStoreReading, @unchecked Sendable {
    private let inner: any VisualStoreReading
    private let delay: TimeInterval
    private let lock = NSLock()
    private var count = 0
    private var onMain: Bool?
    init(wrapping inner: any VisualStoreReading, delay: TimeInterval = 0) { self.inner = inner; self.delay = delay }
    func reads() -> Int { lock.withLock { count } }
    func readOnMain() -> Bool? { lock.withLock { onMain } }
    func visuals() -> [VisualID] { inner.visuals() }
    func blockState(_ id: VisualID) -> BlockState? { inner.blockState(id) }
    func blockState(_ id: VisualID, checkpoint: Int) -> BlockState? { inner.blockState(id, checkpoint: checkpoint) }
    func revisions(_ id: VisualID) -> [Int] { inner.revisions(id) }
    func revision(_ id: VisualID, r: Int) -> VisualRevision? { inner.revision(id, r: r) }
    func read(_ id: VisualID, r: Int, name: String, offset: Int64, limit: Int) -> VisualFileSlice? {
        lock.withLock { count += 1; onMain = Thread.isMainThread }
        if delay > 0 { Thread.sleep(forTimeInterval: delay) }
        return inner.read(id, r: r, name: name, offset: offset, limit: limit)
    }
}
