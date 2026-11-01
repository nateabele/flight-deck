import FleetKit
import Network
import WebKit
import XCTest
@testable import FlightDeckMobile

/// A page in the viewer cannot reach the network (V3 review 1, parked): not by navigating, which
/// `decidePolicyFor` sees, and not by an `<img>` or a stylesheet, which it never does. Those are
/// stopped by the content rule list and the page's policy, and a rule list is untestable as text
/// alone, so this loads a real page that names a loopback server and counts who came.
///
/// The control matters: a counter that can never fire proves nothing. The same markup in a plain
/// web view must reach the server, or the other two results mean only that the server was deaf.
@MainActor
final class VisualSubresourceBlockTests: XCTestCase {
    /// A loopback server that does nothing but count the connections made to it.
    private final class Beacon: @unchecked Sendable {
        private let listener: NWListener
        private let lock = NSLock()
        private var count = 0
        private(set) var port: UInt16 = 0
        var hits: Int { lock.withLock { count } }

        init() throws { listener = try NWListener(using: .tcp, on: .any) }

        func start() async throws {
            listener.newConnectionHandler = { [weak self] connection in
                self?.lock.withLock { self?.count += 1 }
                connection.cancel()
            }
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let once = Once()
                listener.stateUpdateHandler = { state in
                    switch state {
                    case .ready: if once.first() { continuation.resume() }
                    case .failed(let error): if once.first() { continuation.resume(throwing: error) }
                    default: break
                    }
                }
                listener.start(queue: .global())
            }
            port = listener.port?.rawValue ?? 0
        }

        func stop() { listener.cancel() }
    }

    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var used = false
        func first() -> Bool { lock.withLock { defer { used = true }; return !used } }
    }

    private final class Finish: NSObject, WKNavigationDelegate {
        var done = false
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { done = true }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) { done = true }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) { done = true }
    }

    private func markup(port: UInt16) -> String {
        """
        <html><head><link rel="stylesheet" href="http://127.0.0.1:\(port)/site.css"></head>
        <body><img src="http://127.0.0.1:\(port)/pixel.png"><script src="http://127.0.0.1:\(port)/a.js"></script></body></html>
        """
    }

    private func settle(_ finish: Finish) async {
        let until = Date().addingTimeInterval(10)
        while !finish.done, Date() < until { try? await Task.sleep(for: .milliseconds(50)) }
        // Subresource requests start after the document finishes parsing; give a stray one time to arrive.
        try? await Task.sleep(for: .seconds(1.5))
    }

    private func handler(html: String, in dir: URL) -> (VisualSchemeHandler, VisualCache) {
        let cache = VisualCache(directory: dir, budget: 1_000_000)
        let data = Data(html.utf8)
        let sha = VisualCache.sha256Hex(data)
        XCTAssertTrue(cache.store(data, for: VisualKey(visualID: "flow", revision: 1, path: "export/index.html"), sha256: sha))
        let file = WireVisualFile(path: "export/index.html", size: Int64(data.count), sha256: sha)
        return (VisualSchemeHandler(cache: cache, visualID: "flow", revision: 1, files: [file]), cache)
    }

    func testAPlainWebViewReachesTheServerSoTheCounterCanSeeAHit() async throws {
        let beacon = try Beacon()
        try await beacon.start()
        defer { beacon.stop() }
        let finish = Finish()
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        web.navigationDelegate = finish
        web.loadHTMLString(markup(port: beacon.port), baseURL: nil)
        await settle(finish)
        XCTAssertGreaterThan(beacon.hits, 0, "the control: without the rules the page does reach loopback")
    }

    func testTheRuleListAloneStopsSubresourcesOfAPageWithNoPolicyOfItsOwn() async throws {
        let beacon = try Beacon()
        try await beacon.start()
        defer { beacon.stop() }
        let compiled = await VisualWebConfig.compileRules()
        let rules = try XCTUnwrap(compiled)
        let config = WKWebViewConfiguration()
        config.userContentController.add(rules)
        let finish = Finish()
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 480), configuration: config)
        web.navigationDelegate = finish
        web.loadHTMLString(markup(port: beacon.port), baseURL: nil)
        await settle(finish)
        XCTAssertEqual(beacon.hits, 0, "the rule list blocks the img, the stylesheet and the script")
    }

    func testTheViewerAsConfiguredNeverReachesTheServer() async throws {
        let beacon = try Beacon()
        try await beacon.start()
        defer { beacon.stop() }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("VisualSub-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let (handler, _) = handler(html: markup(port: beacon.port), in: dir)
        let compiled = await VisualWebConfig.compileRules()
        let rules = try XCTUnwrap(compiled)
        let config = VisualWebConfig.makeConfiguration(handler: handler, rules: rules)
        let finish = Finish()
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 480), configuration: config)
        web.navigationDelegate = finish
        web.load(URLRequest(url: VisualSchemeHandler.url(visualID: "flow", revision: 1, path: "export/index.html")))
        await settle(finish)
        XCTAssertTrue(finish.done, "the page itself loaded from the handler")
        XCTAssertEqual(beacon.hits, 0)
    }
}
