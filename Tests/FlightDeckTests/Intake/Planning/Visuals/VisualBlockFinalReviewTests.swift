import AppKit
import IntakeKit
import XCTest
@testable import FlightDeck

/// The P2a final review's UI findings (area B, minors): the body's height follows the drawing,
/// the picture and the live view line up, Find's indicator and reveal, the live pool counts views
/// waiting on their picture, a timed-out render is remembered, the block's accessibility, and the
/// snapshot cache's byte bound.
@MainActor
final class VisualBlockFinalReviewTests: XCTestCase {
    private var fixture: VisualFixture!

    override func setUpWithError() throws { fixture = try VisualFixture() }
    override func tearDown() { fixture.remove() }

    /// The first 24 bytes of a PNG: all the header a size reader looks at.
    private static func pngHeader(width: UInt32, height: UInt32) -> Data {
        var d = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13, 0x49, 0x48, 0x44, 0x52])
        for v in [width, height] { withUnsafeBytes(of: v.bigEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: [8, 6, 0, 0, 0, 0, 0, 0, 0])
        return d
    }

    private func model(snapshot: (UInt32, UInt32)?) throws -> VisualBlockModel {
        let extra = snapshot.map { ["snapshot@default-wide.png": Self.pngHeader(width: $0.0, height: $0.1)] } ?? [:]
        try fixture.revision("flow", r: 1, source: VisualFixture.flowchart, kind: "flowchart", states: ["default"], sizes: ["wide"],
                             extra: extra)
        try fixture.block("flow", representations: [1], primary: 1)
        return VisualBlockModel.load(id: "flow", pending: false, store: fixture.store)
    }

    // MARK: - B-M1 body height

    func testTheBodyFollowsTheStoredSnapshotsShapeWithinBounds() throws {
        let wide = try model(snapshot: (800, 200))
        XCTAssertEqual(wide.aspect ?? 0, 4, accuracy: 0.001)
        XCTAssertEqual(VisualBlockLayout.height(for: wide, width: 800), VisualBlockLayout.header + 200)
        XCTAssertEqual(VisualBlockLayout.height(for: wide, width: 400), VisualBlockLayout.header + 160, "never under 160")
        let tall = try model(snapshot: (300, 900))
        XCTAssertEqual(VisualBlockLayout.height(for: tall, width: 800), VisualBlockLayout.header + 640, "never over 640")
    }

    func testWithNoSnapshotTheLiveDrawingsShapeIsUsed() throws {
        let none = try model(snapshot: nil)
        XCTAssertNil(none.aspect)
        XCTAssertEqual(VisualBlockLayout.height(for: none, width: 800, renderedAspect: 2), VisualBlockLayout.header + 400)
    }

    // MARK: - B-M2 picture alignment

    func testThePictureSitsWhereTheLiveViewDoes() {
        let pane = VisualPane(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
        pane.layout()
        XCTAssertEqual(pane.pictureFrame, pane.contentFrame, "the picture fills the body, as the web view does")
        XCTAssertEqual(pane.pictureAlignment, .alignCenter, "centred, as the fitted page centres the drawing")
    }

    func testAFittedCaptureIsNotReplacedByAFullSizeRender() throws {
        _ = try model(snapshot: nil)
        let m = VisualBlockModel.load(id: "flow", pending: false, store: fixture.store)
        let rep = try XCTUnwrap(m.representations.first)
        let fitted = NSImage(size: NSSize(width: 10, height: 10))
        let key = VisualSnapshotCache.Key(store: VisualStoreIdentity.of(fixture.store), id: rep.revision.id, r: 1,
                                          snapshot: VisualSnapshotKey(state: "default", size: "wide"), fit: true)
        VisualSnapshotCache.shared.put(fitted, for: key)
        let block = VisualBlockView(model: m, caption: "Flow", store: fixture.store)
        block.frame = NSRect(x: 0, y: 0, width: 800, height: 400)
        block.setWantsPictures(true)
        XCTAssertTrue(block.bodyImage === fitted)
        RunLoop.current.run(until: Date().addingTimeInterval(4))
        XCTAssertTrue(block.bodyImage === fitted, "a full-size render must not replace the fitted picture")
    }

    // MARK: - B-M3 Find

    func testFindRevealsBeforeTheIndicatorAndForgetsOnClose() {
        let view = PlanNSTextView(usingTextLayoutManager: true)
        view.string = "Some text to find in."
        var shownWhenRevealed: Int?
        view.onFindMatch = { [weak view] in shownWhenRevealed = view?.indicatorShows }
        view.showFindIndicator(for: NSRange(location: 5, length: 4))
        XCTAssertEqual(shownWhenRevealed, 0, "the block is revealed before the indicator is placed")
        XCTAssertEqual(view.findMatch, NSRange(location: 5, length: 4))
        let hide = NSMenuItem()
        hide.tag = NSTextFinder.Action.hideFindInterface.rawValue
        view.performTextFinderAction(hide)
        XCTAssertNil(view.findMatch, "closing Find forgets its match")
    }

    // MARK: - B-M4 pool

    func testWebViewsWaitingOnTheirPictureCountTowardThePool() {
        let pool = VisualLivePool()
        XCTAssertTrue(pool.hasRoom)
        for _ in 0..<VisualLivePool.limit { pool.beginRetiring() }
        XCTAssertFalse(pool.hasRoom, "three views waiting on their capture fill the pool")
        pool.endRetiring()
        XCTAssertTrue(pool.hasRoom)
    }

    // MARK: - B-M5 timed-out render

    func testARenderThatFailedIsNotQueuedAgain() async throws {
        let cache = VisualSnapshotCache()
        var calls = 0
        cache.renderer = { _, _ in calls += 1; return nil }
        let key = VisualSnapshotCache.Key(store: "s", id: VisualID(rawValue: "flow")!, r: 1,
                                          snapshot: VisualSnapshotKey(state: "default", size: "wide"))
        for _ in 0..<3 {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                cache.fetch(key, store: fixture.store) { _ in c.resume() }
            }
        }
        XCTAssertEqual(calls, 1, "a render that timed out is remembered for the session")
    }

    // MARK: - B-M6 accessibility

    func testTheBlocksValueAndControlsAreNamedFromTheStart() throws {
        try fixture.revision("flow", r: 1, source: VisualFixture.flowchart, kind: "flowchart", states: ["default", "error"],
                             sizes: ["wide", "narrow"])
        try fixture.block("flow", representations: [1], primary: 1)
        let block = VisualBlockView(model: VisualBlockModel.load(id: "flow", pending: false, store: fixture.store),
                                    caption: "Flow", store: fixture.store)
        XCTAssertEqual(block.accessibilityValue() as? String, "picture", "set at creation, not first change")
        func control(_ id: String) -> NSSegmentedControl? {
            var stack: [NSView] = [block]
            while let v = stack.popLast() {
                if let c = v as? NSSegmentedControl, c.accessibilityIdentifier() == id { return c }
                stack += v.subviews
            }
            return nil
        }
        XCTAssertEqual(control("visual-states")?.accessibilityLabel(), "State")
        XCTAssertEqual(control("visual-sizes")?.accessibilityLabel(), "Size")
        block.liveStatusChanged(.failed(message: "Parse error on line 2", height: 0))
        XCTAssertTrue((block.accessibilityValue() as? String)?.contains("Parse error on line 2") == true)
        block.liveStatusChanged(.rendered(width: 400, height: 200))
        XCTAssertFalse((block.accessibilityValue() as? String)?.contains("Parse error") == true, "cleared once it draws")
    }

    // MARK: - B-M7 cache bound

    func testTheSnapshotCacheIsBoundedByBytesNotCount() {
        let cache = VisualSnapshotCache()
        func key(_ n: Int) -> VisualSnapshotCache.Key {
            VisualSnapshotCache.Key(store: "s", id: VisualID(rawValue: "v\(n)")!, r: 1, snapshot: VisualSnapshotKey(state: "default", size: "wide"))
        }
        func image(_ side: Int) -> NSImage {
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 4,
                                       hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            let image = NSImage(size: NSSize(width: side, height: side))
            image.addRepresentation(rep)
            return image
        }
        for n in 0..<100 { cache.put(image(16), for: key(n)) }
        XCTAssertNotNil(cache.image(key(0)), "a hundred small pictures fit: the bound is bytes, not 64 entries")
        // 3 × 2500² × 4 B ≈ 75 MB: over 64 MB, so the oldest go.
        for n in 100..<103 { cache.put(image(2500), for: key(n)) }
        XCTAssertNil(cache.image(key(0)))
        XCTAssertNil(cache.image(key(100)), "the oldest big picture went too")
        XCTAssertNotNil(cache.image(key(102)))
        XCTAssertLessThanOrEqual(cache.bytes, VisualSnapshotCache.byteCapacity)
    }
}
