import CryptoKit
import Foundation
import IntakeKit

/// The vendored `mermaid.min.js` (V-R5): `Resources/Visuals/mermaid/`, pinned to one version, with
/// the file's SHA-256 in `manifest.json` beside it.
///
/// **The hash is checked every time the file is loaded, not once at build.** The bundle is code
/// that runs inside a web view the plan drives, and a file swapped in an installed app (or a bad
/// copy) must draw nothing rather than run. A mismatch is `nil`, and the page then says the
/// library failed its check.
enum MermaidLibrary {
    static let fileName = "mermaid.min.js"

    struct Loaded: Sendable {
        let data: Data
        let version: String
    }

    enum Failure: Error, Equatable {
        case missing, badManifest, hashMismatch, sizeMismatch
    }

    private struct Manifest: Decodable {
        struct File: Decodable { let sha256: String; let size: Int }
        let version: String
        let files: [String: File]
    }

    /// Reads `root/mermaid.min.js` and checks it against `root/manifest.json`.
    static func load(root: URL) -> Result<Loaded, Failure> {
        guard let manifestData = try? Data(contentsOf: root.appendingPathComponent("manifest.json")) else { return .failure(.missing) }
        guard let manifest = try? JSONDecoder().decode(Manifest.self, from: manifestData),
              let entry = manifest.files[fileName] else { return .failure(.badManifest) }
        guard let data = try? Data(contentsOf: root.appendingPathComponent(fileName), options: .mappedIfSafe) else { return .failure(.missing) }
        guard data.count == entry.size else { return .failure(.sizeMismatch) }
        let hex = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard hex == entry.sha256.lowercased() else { return .failure(.hashMismatch) }
        return .success(Loaded(data: data, version: manifest.version))
    }

    /// `Contents/Resources/Visuals/mermaid` in the app, or the same folder in whichever loaded
    /// bundle has it: under `xctest` the app is not `Bundle.main`, and the test bundle carries
    /// its own copy (project.yml).
    static func bundledRoot() -> URL? {
        for bundle in [Bundle.main] + Bundle.allBundles {
            if let url = bundle.url(forResource: "Visuals", withExtension: nil)?.appendingPathComponent("mermaid", isDirectory: true),
               FileManager.default.fileExists(atPath: url.appendingPathComponent(fileName).path) { return url }
        }
        return nil
    }

    /// The bundled library, loaded and checked once per process: 5.5 MB is hashed in a few
    /// milliseconds, but not on every block a plan scrolls past.
    static let bundled: Result<Loaded, Failure> = bundledRoot().map(load(root:)) ?? .failure(.missing)
}

/// The page that draws one Mermaid revision (provider `fd.diagram.mermaid`), served by
/// `VisualSchemeHandler` at `fdvisual://<id>/r<n>/`.
///
/// - **No inline script.** The page's policy allows scripts only from `fdvisual:`, so the source
///   travels as an inert JSON block and `fd-mermaid.js` (below) is served beside the library.
///   A diagram whose text tried to close the JSON block is escaped (`<` as `<`).
/// - **No network.** `default-src 'none'`: nothing the diagram names can be fetched, on top of the
///   navigation policy and the non-persistent store (`VisualWebConfiguration`).
/// - **A parse error is drawn, not swallowed.** Mermaid's own message shows in the page (and so
///   in its snapshot), and the page posts it to the app, so the block and the snapshot say the
///   same thing (Review Focus 3).
/// - **Paper.** A white page in Mermaid's default theme, in the app's light and dark alike, so a
///   live diagram and its snapshot look the same and the phone shows the same picture.
enum MermaidPage {
    static let bootstrapName = "fd-mermaid.js"

    static func html(id: VisualID, source: String?, state: String?, size: String?, error: String? = nil) -> String {
        var config: [String: Any] = ["source": source ?? ""]
        if let state { config["state"] = state }
        if let size { config["size"] = size }
        if let error { config["error"] = error }
        let json = (try? JSONSerialization.data(withJSONObject: config, options: [.sortedKeys]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let safe = json.replacingOccurrences(of: "<", with: "\\u003c").replacingOccurrences(of: ">", with: "\\u003e")
            .replacingOccurrences(of: "&", with: "\\u0026")
        let lib = VisualScheme.url(.library(id, name: MermaidLibrary.fileName)).absoluteString
        let boot = VisualScheme.url(.library(id, name: bootstrapName)).absoluteString
        return """
        <!doctype html>
        <html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src fdvisual:; style-src 'unsafe-inline'; img-src fdvisual: data:; font-src fdvisual: data:">
        <style>
        html, body { margin: 0; padding: 0; background: #ffffff; color: #1d1d1f; }
        body { font: 13px -apple-system, system-ui, sans-serif; overflow: hidden; display: flow-root; }
        #out { display: flex; justify-content: center; padding: 16px; }
        #out svg { max-width: 100%; height: auto; }
        .fd-fit #out { box-sizing: border-box; height: 100vh; align-items: center; }
        .fd-fit #out svg { max-height: calc(100vh - 32px); }
        #err { margin: 16px; padding: 12px 14px; border-radius: 8px; border: 1px solid #d70015; color: #a1000f;
               background: #fff2f3; font: 12px ui-monospace, Menlo, monospace; white-space: pre-wrap; }
        #err strong { display: block; font: 600 13px -apple-system, system-ui, sans-serif; margin-bottom: 6px; }
        </style></head>
        <body>
        <div id="out"></div>
        <div id="err" hidden><strong>Mermaid could not draw this diagram</strong><span id="err-text"></span></div>
        <script type="application/json" id="fd-config">\(safe)</script>
        <script src="\(lib)"></script>
        <script src="\(boot)"></script>
        </body></html>
        """
    }

    /// Reads the config, draws the diagram, and posts what happened to `fdvisual`
    /// (`VisualWebView`): `{status: "rendered", width, height}` or `{status: "error", message,
    /// height}`. `mermaid.parse` first, so a syntax error is Mermaid's message, not a broken SVG.
    static let bootstrap = """
    (function () {
      function post(m) { try { window.webkit.messageHandlers.fdvisual.postMessage(m); } catch (e) {} }
      // The drawing's own height, not the page's: the document is never shorter than the view,
      // so its scrollHeight would size a picture to whatever frame it was first laid out in.
      function height() { return Math.ceil(document.body.getBoundingClientRect().height); }
      var out = document.getElementById('out');
      var err = document.getElementById('err');
      function fail(message) {
        out.textContent = '';
        // The drawing area keeps its padding when empty; the message starts at the page's margin.
        out.style.display = 'none';
        document.getElementById('err-text').textContent = message;
        err.hidden = false;
        post({ status: 'error', message: message, width: Math.ceil(document.body.getBoundingClientRect().width), height: height() });
      }
      var config = {};
      try { config = JSON.parse(document.getElementById('fd-config').textContent); } catch (e) { return fail('The page was built wrong: ' + e); }
      if (config.error) { return fail(config.error); }
      if (typeof mermaid === 'undefined') { return fail('The diagram library did not load.'); }
      if (config.state) { document.body.dataset.state = config.state; }
      mermaid.initialize({ startOnLoad: false, securityLevel: 'strict', theme: 'default',
                           fontFamily: '-apple-system, system-ui, sans-serif' });
      (async function () {
        try {
          await mermaid.parse(config.source);
          var result = await mermaid.render('fd-diagram', config.source);
          out.innerHTML = result.svg;
          var box = out.getBoundingClientRect();
          post({ status: 'rendered', width: Math.ceil(box.width), height: height() });
        } catch (e) {
          var stray = document.getElementById('dfd-diagram');
          if (stray) { stray.remove(); }
          fail(String((e && (e.message || e.str)) || e));
        }
      })();
    })();
    """
}
