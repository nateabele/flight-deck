import FleetKit
import Observation
import SwiftUI
import UIKit
import WebKit

/// Serves a revision's cached files to the viewer's web view as `fdvisual://<id>/r<n>/<path>`
/// (V-R2). **The web view's only door to bytes**, so what it refuses is what a page cannot reach:
/// a URL must name this visual and this revision, a file the ref lists, which is in the cache
/// with the content the ref promised. Anything else, `..` and other schemes included, is refused.
/// No request ever leaves the phone for it.
final class VisualSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "fdvisual"

    enum Resolution: Equatable {
        case file(Data, mime: String)
        case refused
    }

    private let cache: VisualCache
    private let visualID: String
    private let revision: Int
    private let files: [String: WireVisualFile]

    init(cache: VisualCache, visualID: String, revision: Int, files: [WireVisualFile]) {
        self.cache = cache
        self.visualID = visualID
        self.revision = revision
        self.files = Dictionary(files.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
    }

    /// The URL of one of a revision's files; `fragment` and `query` are the viewer's state and
    /// size switches and never change which file is served.
    static func url(visualID: String, revision: Int, path: String, fragment: String? = nil, query: String? = nil) -> URL {
        var c = URLComponents()
        c.scheme = scheme
        c.host = visualID
        c.path = "/r\(revision)/" + path
        c.query = query
        c.fragment = fragment
        return c.url ?? URL(string: "about:blank")!
    }

    /// The pure decision: bytes and type for `url`, or a refusal.
    func resolve(_ url: URL) -> Resolution {
        guard url.scheme == Self.scheme, url.host == visualID else { return .refused }
        let parts = url.path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 3, parts[0].isEmpty, parts[1] == "r\(revision)" else { return .refused }
        let path = parts.dropFirst(2).joined(separator: "/")
        guard let file = files[path],
              let data = cache.data(for: VisualKey(visualID: visualID, revision: revision, path: path), sha256: file.sha256)
        else { return .refused }
        return .file(data, mime: Self.mime(path))
    }

    /// The only navigations the viewer allows: its own scheme, and the blank page a web view
    /// starts on. Every other scheme (http, file, data, javascript, tel, ...) is cancelled, which is what
    /// turns the network off for the page.
    static func allowsNavigation(to url: URL?) -> Bool {
        guard let url else { return false }
        return url.scheme == scheme || url.absoluteString == "about:blank"
    }

    static func mime(_ path: String) -> String {
        switch (path as NSString).pathExtension.lowercased() {
        case "html", "htm": "text/html"
        case "css": "text/css"
        case "js", "mjs": "text/javascript"
        case "json": "application/json"
        case "svg": "image/svg+xml"
        case "png": "image/png"
        case "jpg", "jpeg": "image/jpeg"
        case "gif": "image/gif"
        case "webp": "image/webp"
        case "woff2": "font/woff2"
        case "woff": "font/woff"
        case "ttf": "font/ttf"
        case "otf": "font/otf"
        case "txt", "md": "text/plain"
        default: "application/octet-stream"
        }
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        let url = urlSchemeTask.request.url
        guard let url, case .file(let data, let mime) = resolve(url) else {
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        // A policy on every response too: no script, and nothing but this scheme (and data:) to load.
        let headers = [
            "Content-Type": mime,
            "Content-Length": String(data.count),
            "X-Content-Type-Options": "nosniff",
            "Content-Security-Policy": VisualWebConfig.contentSecurityPolicy,
        ]
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)
            ?? URLResponse(url: url, mimeType: mime, expectedContentLength: data.count, textEncodingName: nil)
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}
}

/// How the viewer's web view is locked down, in one place so a test can pin it.
enum VisualWebConfig {
    /// Sent on every `fdvisual:` response.
    static let contentSecurityPolicy = "default-src 'none'; img-src fdvisual:; style-src fdvisual: 'unsafe-inline'; font-src fdvisual:; "
        + "frame-src 'none'; base-uri 'none'; form-action 'none'; script-src 'none'"

    /// Content-blocker rules. `decidePolicyFor` only sees navigations, never an `<img>`, a
    /// stylesheet, a font or an `@import`, so this is what stops those: block every URL, then
    /// un-block our own scheme.
    static let contentRuleListJSON = """
    [{"trigger":{"url-filter":".*"},"action":{"type":"block"}},\
    {"trigger":{"url-filter":"^fdvisual:"},"action":{"type":"ignore-previous-rules"}}]
    """

    static let ruleListIdentifier = "io.radify.flightdeck.visual-viewer.v1"

    /// Compiles the rules. A failure is a failure to open the viewer, never a viewer without them.
    @MainActor static func compileRules() async -> WKContentRuleList? {
        try? await WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: ruleListIdentifier, encodedContentRuleList: contentRuleListJSON)
    }

    /// Non-persistent store (nothing written to disk), our handler as the only source, no script.
    @MainActor static func makeConfiguration(handler: VisualSchemeHandler, rules: WKContentRuleList?) -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.setURLSchemeHandler(handler, forURLScheme: VisualSchemeHandler.scheme)
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        if let rules { config.userContentController.add(rules) }
        return config
    }
}

/// The viewer's state: which of the revision's files it opens, and the state and size switches.
@MainActor
@Observable
final class VisualViewerModel {
    enum Phase: Equatable {
        case loading
        /// The revision's html is cached; the web view can load `entryURL`.
        case live
        /// No html to run (a diagram): the snapshot is the viewer.
        case snapshot(Data?)
        case failed
    }

    let intake: UUID
    let ref: WireVisualRef
    var state: String?
    var size: String?
    private(set) var phase: Phase = .loading
    private(set) var rules: WKContentRuleList?
    @ObservationIgnored private let loader: VisualLoader?

    init(intake: UUID, ref: WireVisualRef, state: String?, loader: VisualLoader?) {
        self.intake = intake
        self.ref = ref
        self.state = state ?? VisualBlockStyle.state(for: ref)
        self.size = VisualBlockStyle.size(for: ref)
        self.loader = loader
    }

    /// The file the web view opens: the export's `index.html`, else the first html file under
    /// `export/` by name, else the first html file by name; nil when the revision has none (a
    /// diagram: its snapshot is the viewer).
    ///
    /// This is the layout V1 and V2 write: a comp's `export/` folder with its `index.html`, and
    /// snapshots named `snapshot@<state>-<size>.png`. Nothing writes a page per state, so a state is
    /// never a file here, only the fragment on the one page.
    nonisolated static func entryPath(in files: [WireVisualFile]) -> String? {
        let pages = files.map(\.path).filter { $0.lowercased().hasSuffix(".html") }.sorted()
        if pages.contains("export/index.html") { return "export/index.html" }
        return pages.first { $0.hasPrefix("export/") } ?? pages.first
    }

    var entryPath: String? { ref.files.flatMap { Self.entryPath(in: $0) } }

    var entryURL: URL? {
        guard let path = entryPath else { return nil }
        // The state is a fragment on the page, which its CSS can key off (`:target`); the size is a
        // query it may read. Neither changes the file served.
        return VisualSchemeHandler.url(visualID: ref.id, revision: ref.revision, path: path, fragment: state,
                                       query: size.map { "size=\($0)" })
    }

    /// How wide the page is held for `size`, or nil for the whole screen: a size name the Mac draws
    /// at 390 points (`phone`) is centred at 390 on a wider screen, and one as wide as the screen or
    /// wider fills it.
    nonisolated static func pageWidth(size: String?, screen: CGFloat) -> CGFloat? {
        guard let size else { return nil }
        let width = CGFloat(VisualSizeWidth.width(size))
        return width < screen ? width : nil
    }

    func handler() -> VisualSchemeHandler? {
        guard let files = ref.files else { return nil }
        return VisualSchemeHandler(cache: .shared, visualID: ref.id, revision: ref.revision, files: files)
    }

    /// Fetches the revision's files, so the page runs from bytes already on the phone. Falls back
    /// to the snapshot when there is no html.
    func load() async {
        phase = .loading
        guard let loader else { phase = .failed; return }
        if entryPath != nil {
            // Rules first, and fail closed: a web view that could load a subresource from the
            // network is never shown.
            rules = await VisualWebConfig.compileRules()
            guard rules != nil else { phase = .failed; return }
            phase = await loader.ensureAll(intake: intake, ref: ref) ? .live : .failed
        } else {
            let data = await loader.snapshot(intake: intake, ref: ref, state: state, size: size)
            phase = data == nil ? .failed : .snapshot(data)
        }
    }

    /// A state or size switch on the snapshot fallback fetches that snapshot.
    func reloadSnapshot() async {
        guard entryPath == nil, let loader else { return }
        let data = await loader.snapshot(intake: intake, ref: ref, state: state, size: size)
        phase = data == nil ? .failed : .snapshot(data)
    }
}

/// The full-screen viewer: the revision's page in a web view that can reach nothing but the
/// bytes already on the phone, with state and size switches.
struct VisualViewerScreen: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.visualLoader) private var loader
    @State private var model: VisualViewerModel?
    let intake: UUID
    let ref: WireVisualRef
    let initialState: String?

    var body: some View {
        NavigationStack {
            Group {
                if let model { content(model) } else { ProgressView() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.systemBackground))
            .navigationTitle(ref.id)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) { if let model { switches(model) } }
            }
        }
        .task {
            let m = VisualViewerModel(intake: intake, ref: ref, state: initialState, loader: loader)
            model = m
            await m.load()
        }
    }

    @ViewBuilder private func content(_ model: VisualViewerModel) -> some View {
        switch model.phase {
        case .loading:
            ProgressView("Loading…")
        case .failed:
            VStack(spacing: 12) {
                Text("Couldn't load this visual.").font(.subheadline).foregroundStyle(.secondary)
                Button("Retry") { Task { await model.load() } }
            }
        case .snapshot(let data):
            if let data, let image = UIImage(data: data) {
                ScrollView([.horizontal, .vertical]) { Image(uiImage: image).resizable().scaledToFit().frame(maxWidth: .infinity) }
            }
        case .live:
            if let url = model.entryURL, let handler = model.handler() {
                VisualWebView(url: url, handler: handler, rules: model.rules)
                    // The size switch: a size narrower than the screen is that wide and centred, a wider one
                    // the full screen.
                    .frame(maxWidth: VisualViewerModel.pageWidth(size: model.size, screen: UIScreen.main.bounds.width) ?? .infinity)
            }
        }
    }

    @ViewBuilder private func switches(_ model: VisualViewerModel) -> some View {
        if ref.states.count > 1 || (ref.sizes ?? []).count > 1 {
            Menu {
                if ref.states.count > 1 {
                    Picker("State", selection: Binding(get: { model.state ?? "" }, set: { model.state = $0; Task { await model.reloadSnapshot() } })) {
                        ForEach(ref.states, id: \.self) { Text($0).tag($0) }
                    }
                }
                if (ref.sizes ?? []).count > 1 {
                    Picker("Size", selection: Binding(get: { model.size ?? "" }, set: { model.size = $0; Task { await model.reloadSnapshot() } })) {
                        ForEach(ref.sizes ?? [], id: \.self) { Text($0).tag($0) }
                    }
                }
            } label: { Label("View", systemImage: "slider.horizontal.3") }
        }
    }
}

/// The web view. **Locked down on purpose**: a non-persistent store (nothing written to disk),
/// the `fdvisual:` handler as its only source, no script (a comp export is static HTML and CSS),
/// and every navigation to another scheme cancelled, new windows included.
private struct VisualWebView: UIViewRepresentable {
    let url: URL
    let handler: VisualSchemeHandler
    let rules: WKContentRuleList?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let config = VisualWebConfig.makeConfiguration(handler: handler, rules: rules)
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = context.coordinator
        web.uiDelegate = context.coordinator
        web.isInspectable = false
        context.coordinator.shown = url
        web.load(URLRequest(url: url))
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {
        guard context.coordinator.shown != url else { return }
        context.coordinator.shown = url
        web.load(URLRequest(url: url))
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var shown: URL?

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            decisionHandler(VisualSchemeHandler.allowsNavigation(to: navigationAction.request.url) ? .allow : .cancel)
        }

        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? { nil }
    }
}
