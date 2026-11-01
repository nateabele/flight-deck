import FleetKit
import Network
import WebKit
import XCTest
@testable import FlightDeckMobile

/// An interactive comp runs its JavaScript on the phone, and that script still reaches nothing but
/// the revision's own bytes. Script widens what a page can try (fetch, sockets, workers, WebRTC,
/// the camera, a child frame's fresh globals), so each route is tried by a real page against a
/// loopback server that counts who came. The control proves the same script in a plain web view
/// does reach it, or a zero would only mean the server was deaf.
@MainActor
final class VisualScriptTests: XCTestCase {
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

    private final class Finish: NSObject, WKNavigationDelegate, WKUIDelegate {
        var done = false
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { done = true }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) { done = true }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) { done = true }
        // The viewer's own navigation rule, so the viewer case is the viewer as shipped.
        var policy: ((URL?) -> Bool)?
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            decisionHandler((policy?(navigationAction.request.url) ?? true) ? .allow : .cancel)
        }
    }

    private var dirs: [URL] = []
    override func tearDown() {
        for d in dirs { try? FileManager.default.removeItem(at: d) }
        dirs = []
        super.tearDown()
    }

    private func handler(_ files: [String: String]) -> VisualSchemeHandler {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("VisualScript-\(UUID())", isDirectory: true)
        dirs.append(dir)
        let cache = VisualCache(directory: dir, budget: 1_000_000)
        var wire: [WireVisualFile] = []
        for (path, text) in files.sorted(by: { $0.key < $1.key }) {
            let data = Data(text.utf8)
            let sha = VisualCache.sha256Hex(data)
            XCTAssertTrue(cache.store(data, for: VisualKey(visualID: "flow", revision: 1, path: path), sha256: sha))
            wire.append(WireVisualFile(path: path, size: Int64(data.count), sha256: sha))
        }
        return VisualSchemeHandler(cache: cache, visualID: "flow", revision: 1, files: wire)
    }

    /// The viewer exactly as `VisualViewerScreen` builds it, on `export/index.html`.
    private func viewer(_ files: [String: String]) async throws -> (WKWebView, Finish) {
        let compiled = await VisualWebConfig.compileRules()
        let rules = try XCTUnwrap(compiled)
        let config = VisualWebConfig.makeConfiguration(handler: handler(files), rules: rules)
        let finish = Finish()
        finish.policy = VisualSchemeHandler.allowsNavigation(to:)
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 600), configuration: config)
        web.navigationDelegate = finish
        web.uiDelegate = finish
        web.load(URLRequest(url: VisualSchemeHandler.url(visualID: "flow", revision: 1, path: "export/index.html")))
        await settle(finish, extra: 0.5)
        return (web, finish)
    }

    private func settle(_ finish: Finish, extra: Double) async {
        let until = Date().addingTimeInterval(10)
        while !finish.done, Date() < until { try? await Task.sleep(for: .milliseconds(50)) }
        try? await Task.sleep(for: .seconds(extra))
    }

    private func eval(_ web: WKWebView, _ js: String) async throws -> String? {
        try await web.evaluateJavaScript(js) as? String
    }

    // MARK: - Script runs

    func testACompsScriptRunsInlineAndFromItsOwnFilesAndCanFetchItsOwnData() async throws {
        let (web, finish) = try await viewer([
            "export/index.html": """
                <html><head><script>document.title = 'inline';</script><script src="app.js"></script></head>
                <body><button id="b" onclick="this.textContent = 'tapped'">tap</button></body></html>
                """,
            "export/app.js": """
                window.fromFile = 'yes';
                fetch('data.json').then(r => r.json()).then(j => { window.fetched = j.ok; }).catch(e => { window.fetched = 'error: ' + e; });
                """,
            "export/data.json": #"{"ok":"ok"}"#,
        ])
        XCTAssertTrue(finish.done)
        try? await Task.sleep(for: .seconds(1))
        let title = try await eval(web, "document.title")
        let fromFile = try await eval(web, "String(window.fromFile)")
        let fetched = try await eval(web, "String(window.fetched)")
        let tapped = try await eval(web, "document.getElementById('b').click(); document.getElementById('b').textContent")
        XCTAssertEqual(title, "inline", "an inline script in the comp runs")
        XCTAssertEqual(fromFile, "yes", "a script file from the revision runs")
        XCTAssertEqual(fetched, "ok", "the comp can fetch one of its own files")
        XCTAssertEqual(tapped, "tapped", "an inline handler runs")
    }

    // MARK: - Script reaches nothing

    /// Every way a script can open a connection, aimed at the beacon. WebRTC goes through TURN over
    /// TCP so the TCP beacon can see it; the child-frame line uses a fresh frame's own globals.
    private func attempts(port: UInt16) -> String {
        """
        (() => {
          const u = 'http://127.0.0.1:\(port)/';
          const t = (f) => { try { f(); } catch (e) {} };
          const ice = { iceServers: [{ urls: 'turn:127.0.0.1:\(port)?transport=tcp', username: 'u', credential: 'c' }] };
          const rtc = (C) => { const pc = new C(ice); pc.createDataChannel('d'); pc.createOffer().then(o => pc.setLocalDescription(o)).catch(() => {}); };
          t(() => fetch(u + 'fetch').catch(() => {}));
          t(() => { const x = new XMLHttpRequest(); x.open('GET', u + 'xhr'); x.send(); });
          t(() => new WebSocket('ws://127.0.0.1:\(port)/ws'));
          t(() => { new Image().src = u + 'img'; });
          t(() => navigator.sendBeacon(u + 'beacon', 'x'));
          t(() => new EventSource(u + 'sse'));
          t(() => import(u + 'module.js').catch(() => {}));
          t(() => new Worker(u + 'worker.js'));
          t(() => rtc(window.RTCPeerConnection));
          t(() => { document.body.insertAdjacentHTML('beforeend', '<iframe></iframe>'); rtc(window.frames[0].RTCPeerConnection); });
          t(() => { const s = document.createElement('script'); s.src = u + 'late.js'; document.head.appendChild(s); });
          t(() => { const f = document.createElement('form'); f.action = u + 'form'; f.method = 'POST'; document.body.appendChild(f); f.submit(); });
          t(() => window.open(u + 'popup'));
          setTimeout(() => t(() => { location.href = u + 'navigate'; }), 400);
        })();
        """
    }

    func testControlTheSameScriptInAPlainWebViewReachesTheBeacon() async throws {
        let beacon = try Beacon()
        try await beacon.start()
        defer { beacon.stop() }
        let finish = Finish()
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
        web.navigationDelegate = finish
        web.loadHTMLString("<html><body><script>\(attempts(port: beacon.port))</script></body></html>", baseURL: nil)
        await settle(finish, extra: 3)
        XCTAssertGreaterThan(beacon.hits, 0, "the control: without the lockdown the script does reach loopback")
    }

    func testControlWebRTCAloneReachesTheBeaconInAPlainWebView() async throws {
        let beacon = try Beacon()
        try await beacon.start()
        defer { beacon.stop() }
        let finish = Finish()
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
        web.navigationDelegate = finish
        let rtcOnly = """
            const pc = new RTCPeerConnection({ iceServers: [{ urls: 'turn:127.0.0.1:\(beacon.port)?transport=tcp', username: 'u', credential: 'c' }] });
            pc.createDataChannel('d'); pc.createOffer().then(o => pc.setLocalDescription(o));
            """
        web.loadHTMLString("<html><body><script>\(rtcOnly)</script></body></html>", baseURL: nil)
        await settle(finish, extra: 3)
        // Not every simulator gathers TURN candidates; when it does not, WebRTC is not a route
        // this test can see, and the API-removal test below is what covers it.
        if beacon.hits == 0 { throw XCTSkip("this simulator gathered no TURN candidate; WebRTC is covered by the removal test") }
    }

    func testTheViewersScriptReachesNothingByAnyRoute() async throws {
        let beacon = try Beacon()
        try await beacon.start()
        defer { beacon.stop() }
        let (web, finish) = try await viewer([
            "export/index.html": "<html><body><script src=\"try.js\"></script></body></html>",
            "export/try.js": attempts(port: beacon.port),
        ])
        XCTAssertTrue(finish.done)
        try? await Task.sleep(for: .seconds(3))
        let ran = try await eval(web, "String(document.querySelectorAll('form').length)")
        XCTAssertEqual(ran, "1", "the attempts script ran (it made its form)")
        XCTAssertEqual(beacon.hits, 0)
    }

    func testWebRTCWorkersAndDeviceAPIsAreGoneInThePageAndInAChildFrame() async throws {
        let (web, _) = try await viewer(["export/index.html": "<html><body></body></html>"])
        let probe = """
            (() => {
              const names = (w) => [typeof w.RTCPeerConnection, typeof w.webkitRTCPeerConnection, typeof w.RTCDataChannel,
                                    typeof w.WebSocket, typeof w.EventSource, typeof w.Worker, typeof w.SharedWorker,
                                    typeof w.navigator.mediaDevices, typeof w.navigator.geolocation,
                                    typeof w.navigator.sendBeacon, typeof w.navigator.serviceWorker].join(',');
              document.body.insertAdjacentHTML('beforeend', '<iframe></iframe>');
              const child = window.frames[0];
              const viaElement = document.querySelector('iframe').contentWindow;
              return JSON.stringify({ page: names(window), child: child ? names(child) : 'none',
                                      element: viaElement == null ? 'null' : 'window' });
            })()
            """
        let out = try await eval(web, probe)
        let json = try XCTUnwrap(out.flatMap { try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: String] })
        let allGone = Array(repeating: "undefined", count: 11).joined(separator: ",")
        XCTAssertEqual(json["page"], allGone)
        XCTAssertTrue(json["child"] == allGone || json["child"] == "none", "a child frame's own globals are gone too: \(json["child"] ?? "")")
        XCTAssertEqual(json["element"], "null", "an iframe hands out no window")
    }

    func testCameraAndMicrophoneAreDeniedWithoutAsking() {
        XCTAssertEqual(VisualWebConfig.mediaCaptureDecision, .deny)
    }
}
