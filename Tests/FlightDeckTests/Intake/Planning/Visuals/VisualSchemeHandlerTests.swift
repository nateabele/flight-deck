import IntakeKit
import WebKit
import XCTest
@testable import FlightDeck

/// Review Focus 5 (V-R2): a visual's web view sees only what `VisualSchemeHandler` serves, and the
/// handler reads a revision's files only through `VisualStoreReading.read`. A file the manifest
/// does not list, a symlink out of the folder and a hard link are never served, and an `http`
/// navigation is cancelled.
@MainActor
final class VisualSchemeHandlerTests: XCTestCase {
    private var fixture: VisualFixture!
    private var outside: URL!
    private let id = VisualID(rawValue: "pairing-handshake")!

    override func setUpWithError() throws {
        fixture = try VisualFixture()
        outside = FileManager.default.temporaryDirectory.appendingPathComponent("VisualOutside-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("secret".utf8).write(to: outside.appendingPathComponent("secret.txt"))
    }

    override func tearDown() {
        fixture.remove()
        try? FileManager.default.removeItem(at: outside)
    }

    /// Every `read` the handler makes, so a test can see a refusal came from the store.
    final class RecordingStore: VisualStoreReading, @unchecked Sendable {
        let inner: any VisualStoreReading
        private(set) var reads: [String] = []
        init(_ inner: any VisualStoreReading) { self.inner = inner }
        func visuals() -> [VisualID] { inner.visuals() }
        func blockState(_ id: VisualID) -> BlockState? { inner.blockState(id) }
        func blockState(_ id: VisualID, checkpoint: Int) -> BlockState? { inner.blockState(id, checkpoint: checkpoint) }
        func revisions(_ id: VisualID) -> [Int] { inner.revisions(id) }
        func revision(_ id: VisualID, r: Int) -> VisualRevision? { inner.revision(id, r: r) }
        func read(_ id: VisualID, r: Int, name: String, offset: Int64, limit: Int) -> VisualFileSlice? {
            reads.append(name)
            return inner.read(id, r: r, name: name, offset: offset, limit: limit)
        }
    }

    final class FakeTask: NSObject, WKURLSchemeTask {
        let request: URLRequest
        var response: URLResponse?
        var data = Data()
        var finished = false
        var error: Error?
        init(_ url: URL) { request = URLRequest(url: url) }
        func didReceive(_ response: URLResponse) { self.response = response }
        func didReceive(_ data: Data) { self.data.append(data) }
        func didFinish() { finished = true }
        func didFailWithError(_ error: Error) { self.error = error }
    }

    private func serve(_ handler: VisualSchemeHandler, _ url: URL) -> FakeTask {
        let task = FakeTask(url)
        handler.webView(WKWebView(), start: task)
        return task
    }

    private func file(_ name: String) -> URL { VisualScheme.url(.file(id, r: 1, path: name)) }

    // MARK: - Served

    func testAListedFileIsServedThroughTheStore() throws {
        try fixture.revision(id.rawValue, r: 1, source: VisualFixture.sequence, extra: ["notes/readme.txt": Data("hi".utf8)])
        let store = RecordingStore(fixture.store)
        let task = serve(VisualSchemeHandler(store: store), file("notes/readme.txt"))
        XCTAssertTrue(task.finished)
        XCTAssertNil(task.error)
        XCTAssertEqual(task.data, Data("hi".utf8))
        XCTAssertEqual(store.reads, ["notes/readme.txt"])
    }

    func testThePageIsBuiltFromTheEntryReadThroughTheStore() throws {
        try fixture.revision(id.rawValue, r: 1, source: VisualFixture.sequence)
        let store = RecordingStore(fixture.store)
        let task = serve(VisualSchemeHandler(store: store), VisualScheme.url(.page(id, r: 1, state: nil, size: nil)))
        let html = try XCTUnwrap(String(data: task.data, encoding: .utf8))
        XCTAssertTrue(html.contains("sequenceDiagram"))
        XCTAssertTrue(html.contains("default-src 'none'"), "the page fetches nothing")
        XCTAssertEqual(task.response?.mimeType, "text/html")
        XCTAssertEqual(store.reads, ["diagram.mmd"])
    }

    func testTheDiagramSourceCannotCloseItsJSONBlock() throws {
        try fixture.revision(id.rawValue, r: 1, source: "graph LR\n A[</script><script>alert(1)</script>] --> B")
        let task = serve(VisualSchemeHandler(store: fixture.store), VisualScheme.url(.page(id, r: 1, state: nil, size: nil)))
        let html = try XCTUnwrap(String(data: task.data, encoding: .utf8))
        XCTAssertFalse(html.contains("<script>alert"), html)
    }

    // MARK: - Never served (Review Focus 5)

    func testAFileNotInTheManifestIsNeverServed() throws {
        try fixture.revision(id.rawValue, r: 1, source: VisualFixture.sequence, unlisted: ["stray.txt": Data("stray".utf8)])
        let store = RecordingStore(fixture.store)
        let task = serve(VisualSchemeHandler(store: store), file("stray.txt"))
        XCTAssertNotNil(task.error)
        XCTAssertFalse(task.finished)
        XCTAssertTrue(task.data.isEmpty)
        XCTAssertEqual(store.reads, ["stray.txt"], "the store was asked, and it refused")
    }

    func testTheManifestItselfIsNeverServed() throws {
        try fixture.revision(id.rawValue, r: 1, source: VisualFixture.sequence)
        let task = serve(VisualSchemeHandler(store: fixture.store), file("manifest.json"))
        XCTAssertNotNil(task.error)
        XCTAssertTrue(task.data.isEmpty)
    }

    func testASymlinkOutOfTheFolderIsNeverServedEvenWhenTheManifestListsIt() throws {
        let dir = try fixture.revision(id.rawValue, r: 1, source: VisualFixture.sequence, extra: ["leak.txt": Data("secret".utf8)])
        // Listed with the outside file's size and hash, so only the link itself can be what refuses it.
        try FileManager.default.removeItem(at: dir.appendingPathComponent("leak.txt"))
        try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("leak.txt"), withDestinationURL: outside.appendingPathComponent("secret.txt"))
        let store = RecordingStore(fixture.store)
        let task = serve(VisualSchemeHandler(store: store), file("leak.txt"))
        XCTAssertNotNil(task.error)
        XCTAssertTrue(task.data.isEmpty)
        XCTAssertEqual(store.reads, ["leak.txt"])
    }

    func testASymlinkedFolderOnTheWayIsNeverFollowed() throws {
        let dir = try fixture.revision(id.rawValue, r: 1, source: VisualFixture.sequence, extra: ["sub/secret.txt": Data("secret".utf8)])
        try FileManager.default.removeItem(at: dir.appendingPathComponent("sub"))
        try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("sub"), withDestinationURL: outside)
        let task = serve(VisualSchemeHandler(store: fixture.store), file("sub/secret.txt"))
        XCTAssertNotNil(task.error)
        XCTAssertTrue(task.data.isEmpty)
    }

    func testAHardLinkToAFileOutsideIsNeverServed() throws {
        let dir = try fixture.revision(id.rawValue, r: 1, source: VisualFixture.sequence, extra: ["hard.txt": Data("secret".utf8)])
        try FileManager.default.removeItem(at: dir.appendingPathComponent("hard.txt"))
        try FileManager.default.linkItem(at: outside.appendingPathComponent("secret.txt"), to: dir.appendingPathComponent("hard.txt"))
        let task = serve(VisualSchemeHandler(store: fixture.store), file("hard.txt"))
        XCTAssertNotNil(task.error)
        XCTAssertTrue(task.data.isEmpty)
    }

    func testATraversalIsRefusedByTheStore() throws {
        try fixture.revision(id.rawValue, r: 1, source: VisualFixture.sequence)
        let store = RecordingStore(fixture.store)
        let handler = VisualSchemeHandler(store: store)
        let url = try XCTUnwrap(URL(string: "fdvisual://pairing-handshake/r1/../../../secret.txt"))
        XCTAssertNotEqual(handler.respond(to: url), .ok(Data("secret".utf8), mime: "text/plain"))
        if case .ok = handler.respond(to: url) { XCTFail("served a traversal") }
    }

    func testAnotherSchemeOrAMissingRevisionIsRefused() throws {
        let handler = VisualSchemeHandler(store: fixture.store)
        for raw in ["http://pairing-handshake/r1/diagram.mmd", "file:///etc/passwd", "fdvisual://pairing-handshake/r9/"] {
            if case .ok = handler.respond(to: URL(string: raw)!) { XCTFail(raw) }
        }
    }

    // MARK: - Navigation

    func testOnlyARevisionsPageMayBeTheDocument() {
        XCTAssertTrue(VisualNavigationPolicy.allows(VisualScheme.url(.page(id, r: 1, state: nil, size: nil))))
        XCTAssertFalse(VisualNavigationPolicy.allows(file("diagram.mmd")), "a file is never a document")
        XCTAssertFalse(VisualNavigationPolicy.allows(URL(string: "https://example.com/")))
        XCTAssertFalse(VisualNavigationPolicy.allows(URL(string: "about:blank")))
        XCTAssertFalse(VisualNavigationPolicy.allows(URL(fileURLWithPath: "/etc/passwd")))
    }

    func testAnHTTPNavigationIsCancelled() throws {
        let web = VisualWebView(store: fixture.store)
        web.view.load(URLRequest(url: URL(string: "http://127.0.0.1:9/never")!))
        let until = Date().addingTimeInterval(10)
        while web.cancelled.isEmpty, Date() < until { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        XCTAssertEqual(web.cancelled.map(\.absoluteString), ["http://127.0.0.1:9/never"])
    }

    func testAPageThatNavigatesAwayIsCancelled() throws {
        try fixture.revision(id.rawValue, r: 1, source: VisualFixture.sequence)
        let web = VisualWebView(store: fixture.store)
        var status: VisualRenderStatus?
        web.onStatus = { status = $0 }
        web.show(id, r: 1, state: nil, size: nil)
        var until = Date().addingTimeInterval(20)
        while status == nil, Date() < until { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        XCTAssertNotNil(status, "the page drew")
        web.view.evaluateJavaScript("location.href = 'https://example.com/away'")
        until = Date().addingTimeInterval(10)
        while web.cancelled.isEmpty, Date() < until { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        XCTAssertEqual(web.cancelled.map(\.absoluteString), ["https://example.com/away"])
        XCTAssertEqual(web.view.url, VisualScheme.url(.page(id, r: 1, state: nil, size: nil)), "still on the diagram")
    }

    // MARK: - The vendored library (V-R5)

    func testTheBundledMermaidPassesItsHashCheck() throws {
        let root = try XCTUnwrap(MermaidLibrary.bundledRoot(), "Resources/Visuals is bundled")
        guard case .success(let loaded) = MermaidLibrary.load(root: root) else { return XCTFail("hash check failed") }
        XCTAssertEqual(loaded.version, "12.2.0")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("LICENSE").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("NOTICE").path))
    }

    func testAChangedLibraryFailsItsHashCheckAndIsNotServed() throws {
        let source = try XCTUnwrap(MermaidLibrary.bundledRoot())
        let copy = outside.appendingPathComponent("mermaid", isDirectory: true)
        try FileManager.default.copyItem(at: source, to: copy)
        var bytes = try Data(contentsOf: copy.appendingPathComponent(MermaidLibrary.fileName))
        bytes[100] ^= 0x01
        try bytes.write(to: copy.appendingPathComponent(MermaidLibrary.fileName))
        XCTAssertEqual(MermaidLibrary.load(root: copy).failure, .hashMismatch)
    }
}

private extension Result {
    var failure: Failure? { if case .failure(let f) = self { f } else { nil } }
}
