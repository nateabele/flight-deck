import AppKit
import IntakeKit
import XCTest
@testable import FlightDeck

/// Where a block's pictures come from (V1 review, parked to V4): the stored snapshot decoded once,
/// one draw at a time across every intake, and the picture a live view leaves behind taken before
/// the view goes.
@MainActor
final class VisualBlockPicturesTests: XCTestCase {
    private var fixture: VisualFixture!

    override func setUpWithError() throws { fixture = try VisualFixture() }
    override func tearDown() { fixture.remove() }

    /// Counts the reads of one file, and passes everything through to the disk store.
    private final class CountingStore: VisualStoreReading, @unchecked Sendable {
        let base: DiskVisualStore
        private let lock = NSLock()
        private var counts: [String: Int] = [:]
        init(_ base: DiskVisualStore) { self.base = base }
        func reads(_ name: String) -> Int { lock.withLock { counts[name, default: 0] } }
        func visuals() -> [VisualID] { base.visuals() }
        func blockState(_ id: VisualID) -> BlockState? { base.blockState(id) }
        func blockState(_ id: VisualID, checkpoint: Int) -> BlockState? { base.blockState(id, checkpoint: checkpoint) }
        func revisions(_ id: VisualID) -> [Int] { base.revisions(id) }
        func revision(_ id: VisualID, r: Int) -> VisualRevision? { base.revision(id, r: r) }
        func read(_ id: VisualID, r: Int, name: String, offset: Int64, limit: Int) -> VisualFileSlice? {
            lock.withLock { counts[name, default: 0] += 1 }
            return base.read(id, r: r, name: name, offset: offset, limit: limit)
        }
    }

    private func png() throws -> Data {
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 40, pixelsHigh: 24, bitsPerSample: 8, samplesPerPixel: 4,
                                                 hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    }

    private func wait(_ what: String, timeout: TimeInterval = 30, until condition: () -> Bool) {
        let end = Date().addingTimeInterval(timeout)
        while !condition(), Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        XCTAssertTrue(condition(), what)
    }

    // MARK: - M6: decoded once

    func testAStoredSnapshotIsReadAndDecodedOnceHoweverOftenTheBlockRedraws() throws {
        let name = "snapshot@default-default.png"
        try fixture.revision("shot", r: 1, source: VisualFixture.flowchart, extra: [name: try png()])
        let store = CountingStore(fixture.store)
        let model = VisualBlockModel.load(id: "shot", pending: false, store: store)
        XCTAssertEqual(model.representations.count, 1)
        let block = VisualBlockView(model: model, caption: "c", store: store)
        block.setWantsPictures(true)
        XCTAssertTrue(block.picturesReady, "the stored picture is in")
        // The block redraws its body and its thumbnails on every selection, variant change and scroll.
        block.setWantsPictures(false)
        block.setWantsPictures(true)
        block.update(model: model, caption: "another caption")
        XCTAssertTrue(block.picturesReady)
        XCTAssertEqual(store.reads(name), 1, "read from the store once; later draws reuse the decoded image")
    }

    // MARK: - M2: one draw at a time, across intakes

    func testTwoIntakesDrawThroughOneHostOneAtATime() throws {
        let other = try VisualFixture()
        defer { other.remove() }
        try fixture.revision("a", r: 1, source: VisualFixture.flowchart)
        try other.revision("b", r: 1, source: VisualFixture.sequence)
        let host = VisualRenderHost.shared
        let before = host.drawCount
        host.resetPeak()
        var results: [NSImage?] = []
        let key = VisualSnapshotKey(state: "default", size: "default")
        let cache = VisualSnapshotCache.shared
        cache.fetch(.init(store: VisualStoreIdentity.of(fixture.store), id: VisualID(rawValue: "a")!, r: 1, snapshot: key),
                    store: fixture.store) { results.append($0) }
        cache.fetch(.init(store: VisualStoreIdentity.of(other.store), id: VisualID(rawValue: "b")!, r: 1, snapshot: key),
                    store: other.store) { results.append($0) }
        wait("both drawn") { results.count == 2 }
        XCTAssertTrue(results.allSatisfy { $0 != nil })
        XCTAssertEqual(host.drawCount - before, 2, "both intakes drew through the one host")
        XCTAssertEqual(host.peakConcurrentDraws, 1, "never two web content processes drawing at once")
    }

    // MARK: - M1: the picture a live view leaves behind

    func testALiveViewStaysUntilItsPictureIsTakenThenLeavesIt() throws {
        try fixture.revision("live", r: 1, source: VisualFixture.sequence)
        let store = fixture.store
        let block = VisualBlockView(model: VisualBlockModel.load(id: "live", pending: false, store: store), caption: "c", store: store)
        block.frame = NSRect(x: 0, y: 0, width: 640, height: VisualBlockLayout.height(for: block.model))
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 640, height: 500), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = block
        window.orderFrontRegardless()
        defer { block.goSnapshot(); window.orderOut(nil); window.contentView = nil }
        block.goLive()
        wait("the page drew") { if case .rendered = block.liveStatus { true } else { false } }
        let rep = block.model.representations[0]
        let fitKey = VisualSnapshotCache.Key(store: VisualStoreIdentity.of(store), id: rep.revision.id, r: 1,
                                             snapshot: VisualSnapshotKey(state: "default", size: "default"), fit: true)
        let fullKey = VisualSnapshotCache.Key(store: VisualStoreIdentity.of(store), id: rep.revision.id, r: 1,
                                              snapshot: VisualSnapshotKey(state: "default", size: "default"))
        block.goSnapshot()
        XCTAssertTrue(block.holdsWebView, "the web view is not torn down in the turn that asks for its picture")
        wait("the picture arrived") { VisualSnapshotCache.shared.image(fitKey) != nil }
        wait("then the view went") { !block.holdsWebView }
        XCTAssertNil(VisualSnapshotCache.shared.image(fullKey),
                     "the live view is fitted to the body: it is not the full-size picture and is not filed as one")
    }
}
