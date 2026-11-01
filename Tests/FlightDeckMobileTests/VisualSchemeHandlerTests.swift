import FleetKit
import XCTest
@testable import FlightDeckMobile

/// What the live viewer's `fdvisual:` handler will and will not serve (P2a V3, V-R2). The handler
/// is the web view's only door to bytes, so these run the pure decision (`resolve`) and the
/// navigation rule; no web view is needed to prove what a page can reach.
final class VisualSchemeHandlerTests: XCTestCase {
    private var dir: URL!
    private var cache: VisualCache!
    private let html = Data("<h1>comp</h1>".utf8)
    private let css = Data("h1{color:red}".utf8)

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("VisualScheme-\(UUID())", isDirectory: true)
        cache = VisualCache(directory: dir, budget: 1_000_000)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    private func file(_ path: String, _ data: Data) -> WireVisualFile {
        WireVisualFile(path: path, size: Int64(data.count), sha256: VisualCache.sha256Hex(data))
    }

    private func handler(cached: [(String, Data)], listed: [WireVisualFile]? = nil) -> VisualSchemeHandler {
        for (path, data) in cached {
            XCTAssertTrue(cache.store(data, for: VisualKey(visualID: "flow", revision: 2, path: path), sha256: VisualCache.sha256Hex(data)))
        }
        return VisualSchemeHandler(cache: cache, visualID: "flow", revision: 2,
                                   files: listed ?? [file("export/index.html", html), file("export/site.css", css)])
    }

    private func url(_ s: String) -> URL { URL(string: s)! }

    func testAListedCachedFileIsServedWithItsType() {
        let h = handler(cached: [("export/index.html", html), ("export/site.css", css)])
        XCTAssertEqual(h.resolve(url("fdvisual://flow/r2/export/index.html")), .file(html, mime: "text/html"))
        XCTAssertEqual(h.resolve(url("fdvisual://flow/r2/export/site.css")), .file(css, mime: "text/css"))
        // A query or fragment (the viewer's state and size switches) does not change the file.
        XCTAssertEqual(h.resolve(url("fdvisual://flow/r2/export/index.html?size=narrow#checkout")), .file(html, mime: "text/html"))
    }

    func testAUrlNotInTheCacheIsRefused() {
        let h = handler(cached: [("export/index.html", html)])
        XCTAssertEqual(h.resolve(url("fdvisual://flow/r2/export/site.css")), .refused, "listed, never fetched")
    }

    func testAFileTheManifestDoesNotListIsRefusedEvenIfCached() {
        let sneaky = Data("x".utf8)
        let h = handler(cached: [("export/index.html", html), ("export/extra.js", sneaky)])
        XCTAssertEqual(h.resolve(url("fdvisual://flow/r2/export/extra.js")), .refused)
    }

    func testAnotherRevisionHostSchemeOrTraversalIsRefused() {
        let h = handler(cached: [("export/index.html", html)])
        for bad in ["fdvisual://flow/r1/export/index.html", "fdvisual://other/r2/export/index.html",
                    "https://flow/r2/export/index.html", "file:///etc/passwd",
                    "fdvisual://flow/r2/export/../../etc/passwd", "fdvisual://flow/r2/%2e%2e/index.html",
                    "fdvisual://flow/export/index.html", "fdvisual://flow/", "fdvisual://flow"] {
            XCTAssertEqual(h.resolve(url(bad)), .refused, bad)
        }
    }

    func testOnlyOurSchemeCanBeNavigatedTo() {
        XCTAssertTrue(VisualSchemeHandler.allowsNavigation(to: url("fdvisual://flow/r2/export/index.html")))
        XCTAssertTrue(VisualSchemeHandler.allowsNavigation(to: url("about:blank")))
        for bad in ["https://example.com", "http://example.com", "file:///etc/passwd", "data:text/html,hi",
                    "javascript:alert(1)", "tel:5551212", "mailto:a@b.c"] {
            XCTAssertFalse(VisualSchemeHandler.allowsNavigation(to: url(bad)), bad)
        }
        XCTAssertFalse(VisualSchemeHandler.allowsNavigation(to: nil))
    }

    /// V1 and V2 write `snapshot@<state>-<size>.png` and a comp's `export/` folder with an
    /// `index.html`; nothing writes a page per state, so a state is always a fragment on the one page.
    @MainActor func testTheEntryIsTheExportsIndexAndAStateIsAFragmentOnIt() {
        let files = [file("export/index.html", html), file("export/checkout.html", html), file("snapshot@default-wide.png", html)]
        XCTAssertEqual(VisualViewerModel.entryPath(in: files), "export/index.html")
        XCTAssertEqual(VisualViewerModel.entryPath(in: [file("export/b.html", html), file("export/a.html", html)]), "export/a.html",
                       "no index: the first export page by name")
        XCTAssertEqual(VisualViewerModel.entryPath(in: [file("page.html", html), file("export/z.html", html)]), "export/z.html")
        XCTAssertNil(VisualViewerModel.entryPath(in: [file("snapshot@default-wide.png", html)]), "no html: snapshot only")
        let ref = WireVisualRef(id: "flow", revision: 2, states: ["default", "checkout"], sizes: ["wide", "phone"], files: files)
        let model = VisualViewerModel(intake: UUID(), ref: ref, state: "checkout", loader: nil)
        XCTAssertEqual(model.entryURL?.absoluteString, "fdvisual://flow/r2/export/index.html?size=phone#checkout")
        let u = VisualSchemeHandler.url(visualID: "flow", revision: 2, path: "export/index.html", fragment: "checkout")
        XCTAssertEqual(u.absoluteString, "fdvisual://flow/r2/export/index.html#checkout")
    }

    @MainActor func testTheViewerPageIsAsWideAsItsSizeNameAndNoWiderThanTheScreen() {
        XCTAssertEqual(VisualViewerModel.pageWidth(size: "phone", screen: 430), 390)
        XCTAssertNil(VisualViewerModel.pageWidth(size: "phone", screen: 390), "as wide as the screen: no frame")
        XCTAssertNil(VisualViewerModel.pageWidth(size: "wide", screen: 430), "wider than the screen: the screen")
        XCTAssertNil(VisualViewerModel.pageWidth(size: nil, screen: 430))
        XCTAssertEqual(VisualViewerModel.pageWidth(size: "300", screen: 430), 300)
    }
}
