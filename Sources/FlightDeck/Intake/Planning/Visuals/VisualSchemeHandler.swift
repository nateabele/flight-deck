import AppKit
import IntakeKit
import WebKit

/// Serves `fdvisual:` to a visual's web view (V-R2), and nothing else does: the web view has no
/// file URL, no network and no other scheme, so this is the whole of what it can see.
///
/// - A revision's file is read **only** through `VisualStoreReading.read`, which serves only what
///   the revision's manifest lists, and refuses symlinks, hard links, `..` and anything over the
///   size cap (`DiskVisualStore`). This type never builds a path, so it cannot get confinement
///   wrong (Review Focus 5).
/// - The page for a revision (`fdvisual://<id>/r<n>/`) is built here from the manifest and the
///   entry file, which is itself read through `read`.
/// - `lib/` serves the vendored, hash-checked Mermaid and the page's own bootstrap script.
/// - Anything else fails the request.
final class VisualSchemeHandler: NSObject, WKURLSchemeHandler {
    let store: any VisualStoreReading
    /// The vendored library, by name; nil refuses it. The default is the bundled, hash-checked copy.
    let library: @Sendable (String) -> Data?

    init(store: any VisualStoreReading, library: @escaping @Sendable (String) -> Data? = { VisualSchemeHandler.bundledLibrary($0) }) {
        self.store = store
        self.library = library
    }

    nonisolated static func bundledLibrary(_ name: String) -> Data? {
        guard name == MermaidLibrary.fileName, case .success(let loaded) = MermaidLibrary.bundled else { return nil }
        return loaded.data
    }

    enum Response: Equatable {
        case ok(Data, mime: String)
        /// Why it was refused, for the log and the tests; the web view sees only a failed load.
        case refused(String)
    }

    /// What `url` gets. Synchronous and free of WebKit, so the rules are testable on their own.
    func respond(to url: URL) -> Response {
        guard let target = VisualScheme.parse(url) else { return .refused("not a visual URL") }
        switch target {
        case .file(let id, let r, let path):
            guard let slice = store.read(id, r: r, name: path, offset: 0, limit: VisualStoreLimits.maxFileBytes) else {
                return .refused("the store refused \(path)")
            }
            return .ok(slice.data, mime: Self.mime(path))
        case .library(_, let name):
            if name == MermaidPage.bootstrapName { return .ok(Data(MermaidPage.bootstrap.utf8), mime: "text/javascript") }
            guard let data = library(name) else { return .refused("no library \(name)") }
            return .ok(data, mime: "text/javascript")
        case .page(let id, let r, let state, let size):
            guard let revision = store.revision(id, r: r) else { return .refused("no revision r\(r)") }
            return .ok(Data(page(revision, state: state, size: size).utf8), mime: "text/html")
        }
    }

    /// The page for a revision, by what draws it. Mermaid today; another kind says so in the
    /// page rather than failing blank.
    private func page(_ revision: VisualRevision, state: String?, size: String?) -> String {
        let manifest = revision.manifest
        guard VisualRenderer.of(manifest) == .mermaid else {
            return MermaidPage.html(id: revision.id, source: nil, state: state, size: size,
                                    error: "Flight Deck cannot draw a \(manifest.kind) visual yet.")
        }
        guard let slice = store.read(revision.id, r: revision.r, name: manifest.entry, offset: 0, limit: VisualStoreLimits.maxFileBytes),
              let source = String(data: slice.data, encoding: .utf8) else {
            return MermaidPage.html(id: revision.id, source: nil, state: state, size: size,
                                    error: "The diagram's source (\(manifest.entry)) could not be read.")
        }
        if case .failure = MermaidLibrary.bundled, library(MermaidLibrary.fileName) == nil {
            return MermaidPage.html(id: revision.id, source: nil, state: state, size: size,
                                    error: "The bundled Mermaid library failed its integrity check.")
        }
        return MermaidPage.html(id: revision.id, source: source, state: state, size: size)
    }

    static func mime(_ path: String) -> String {
        switch (path as NSString).pathExtension.lowercased() {
        case "png": "image/png"
        case "jpg", "jpeg": "image/jpeg"
        case "svg": "image/svg+xml"
        case "json": "application/json"
        case "html": "text/html"
        case "js": "text/javascript"
        case "css": "text/css"
        case "woff2": "font/woff2"
        default: "text/plain"
        }
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else {
            urlSchemeTask.didFailWithError(URLError(.badURL))
            return
        }
        switch respond(to: url) {
        case .ok(let data, let mime):
            urlSchemeTask.didReceive(URLResponse(url: url, mimeType: mime, expectedContentLength: data.count,
                                                 textEncodingName: mime.hasPrefix("text/") ? "utf-8" : nil))
            urlSchemeTask.didReceive(data)
            urlSchemeTask.didFinish()
        case .refused:
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
        }
    }

    // Every response is complete before `start` returns, so there is nothing to stop.
    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}
}

/// What draws a revision.
enum VisualRenderer: Equatable {
    case mermaid, unsupported

    static func of(_ manifest: VisualManifest) -> VisualRenderer {
        if manifest.provider == "fd.diagram.mermaid" || manifest.kind == "mermaid" || manifest.entry.hasSuffix(".mmd") { return .mermaid }
        return .unsupported
    }
}

/// Which navigations a visual's web view may make: a revision's page on `fdvisual:`, and nothing
/// else — no `http(s)`, no `file:`, no `about:`, and not a revision's own file as a document.
enum VisualNavigationPolicy {
    static func allows(_ url: URL?) -> Bool {
        guard let url, case .page = VisualScheme.parse(url) else { return false }
        return true
    }
}

/// How a draw went, as the page reports it.
enum VisualRenderStatus: Equatable {
    case loading
    case rendered(width: CGFloat, height: CGFloat)
    case failed(message: String, height: CGFloat)
}

/// One web view for one visual, configured the only way a visual's web view is: a
/// `.nonPersistent()` store (nothing is kept between views or written to disk), `fdvisual:`
/// through `VisualSchemeHandler`, every other navigation cancelled, no new windows, and the
/// page's status posted back through `onStatus`.
@MainActor
final class VisualWebView: NSObject, WKNavigationDelegate {
    let view: WKWebView
    var onStatus: ((VisualRenderStatus) -> Void)?
    private(set) var status: VisualRenderStatus = .loading
    /// Navigations this view refused, newest last: what a test checks the policy by.
    private(set) var cancelled: [URL] = []
    private let handler: VisualSchemeHandler

    /// `fit` scales the drawing down to the view's height (a block's body); without it the page
    /// is as tall as the drawing (a snapshot).
    init(store: any VisualStoreReading, frame: NSRect = NSRect(x: 0, y: 0, width: VisualSize.defaultWidth, height: 300),
         fit: Bool = false, library: @escaping @Sendable (String) -> Data? = { VisualSchemeHandler.bundledLibrary($0) }) {
        handler = VisualSchemeHandler(store: store, library: library)
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.setURLSchemeHandler(handler, forURLScheme: VisualScheme.name)
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        let relay = StatusRelay()
        config.userContentController.add(relay, contentWorld: .page, name: "fdvisual")
        if fit {
            // A user script, not a page change: the page's policy allows no inline script, and
            // this is the app's choice about the frame, not the diagram's.
            config.userContentController.addUserScript(WKUserScript(source: "document.documentElement.classList.add('fd-fit')",
                                                                    injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        view = VisualWKWebView(frame: frame, configuration: config)
        super.init()
        view.navigationDelegate = self
        relay.owner = self
    }

    func show(_ id: VisualID, r: Int, state: String?, size: String?) {
        status = .loading
        view.load(URLRequest(url: VisualScheme.url(.page(id, r: r, state: state, size: size))))
    }

    /// Detaches the status relay, so the web view (which retains it) holds nothing of the block.
    func stop() {
        view.stopLoading()
        view.configuration.userContentController.removeScriptMessageHandler(forName: "fdvisual", contentWorld: .page)
        onStatus = nil
    }

    fileprivate func receive(_ body: Any) {
        guard let message = body as? [String: Any], let kind = message["status"] as? String else { return }
        let width = (message["width"] as? NSNumber).map { CGFloat($0.doubleValue) } ?? 0
        let height = (message["height"] as? NSNumber).map { CGFloat($0.doubleValue) } ?? 0
        switch kind {
        case "rendered": status = .rendered(width: width, height: height)
        case "error": status = .failed(message: message["message"] as? String ?? "Unknown error", height: height)
        default: return
        }
        onStatus?(status)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let url = navigationAction.request.url
        if VisualNavigationPolicy.allows(url) { return decisionHandler(.allow) }
        if let url { cancelled.append(url) }
        decisionHandler(.cancel)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        status = .failed(message: "The diagram's web content stopped.", height: 0)
        onStatus?(status)
    }
}

/// The page's messages, relayed to a `VisualWebView` held weakly: the user content controller
/// retains its handlers, and a strong owner here would keep every block's web view alive.
private final class StatusRelay: NSObject, WKScriptMessageHandler {
    weak var owner: VisualWebView?
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        let body = message.body
        MainActor.assumeIsolated { owner?.receive(body) }
    }
}

/// A web view inside the plan's page: the page scrolls, not the diagram. A wheel over a diagram
/// went to WebKit, which had nothing to scroll and kept it, so the plan stopped under the pointer.
final class VisualWKWebView: WKWebView {
    override func scrollWheel(with event: NSEvent) {
        if let scroll = superview?.enclosingScrollView { scroll.scrollWheel(with: event) } else { nextResponder?.scrollWheel(with: event) }
    }
}
