import FleetKit
import SwiftUI

/// A link in a transcript that names a file on the Mac, and what the phone draws it as.
///
/// **Decided from the link alone, before anything is fetched**, so a tap on a link this app
/// cannot show (a directory, a `.zip`, a web address) falls through to the system exactly as
/// it did before this existed, instead of pushing a screen that can only say "can't open".
///
/// The shapes agents actually write: `[x](docs/HANDOFF.md)` relative to where the agent was
/// working, `/Users/…/plan.md`, `~/…`, `file:///…`, and a line on the end as `:42`, `:42:7`
/// or `#L42` / `#L42-L50`.
struct LocalFileLink: Hashable {
    enum Kind: Hashable {
        case markdown
        /// `code`: drawn in the monospace, a line per line. Otherwise the reading face.
        case text(code: Bool)
        case image
    }

    /// As the link wrote it, line suffix removed: the Mac resolves a relative one.
    let path: String
    let line: Int?
    let kind: Kind

    var fileName: String { (path as NSString).lastPathComponent }

    init?(_ url: URL) {
        self.init(string: url.absoluteString)
    }

    init?(string raw: String) {
        var text = raw
        if text.hasPrefix("file://") {
            guard let url = URL(string: text), url.isFileURL, url.host.map({ $0.isEmpty || $0 == "localhost" }) ?? true
            else { return nil }
            text = url.path
            if let fragment = url.fragment { text += "#" + fragment }
        } else {
            // A scheme is a web address, `mailto:`, an app link — anything but a file. A bare
            // `Foo.swift:42` parses as scheme `foo.swift`, which is why a dot rules a scheme out.
            if let colon = text.firstIndex(of: ":"),
               !text[..<colon].contains("/"), !text[..<colon].contains("."),
               text[..<colon].allSatisfy({ $0.isLetter || $0.isNumber || "+-".contains($0) }) {
                return nil
            }
            text = text.removingPercentEncoding ?? text
        }
        guard !text.isEmpty, !text.hasPrefix("#"), !text.hasPrefix("?") else { return nil }

        var line: Int?
        if let hash = text.range(of: "#L", options: .backwards) {
            let digits = text[hash.upperBound...].prefix { $0.isNumber }
            line = Int(digits)
            text = String(text[..<hash.lowerBound])
        } else if let match = text.range(of: #":(\d+)(:\d+)?$"#, options: .regularExpression) {
            line = Int(text[match].dropFirst().prefix { $0.isNumber })
            text = String(text[..<match.lowerBound])
        }
        guard !text.hasSuffix("/"), let kind = Self.kind(of: text) else { return nil }
        self.path = text
        self.line = line
        self.kind = kind
    }

    init(path: String, line: Int?, kind: Kind) {
        self.path = path; self.line = line; self.kind = kind
    }

    /// The same link, absolute against `directory` — a markdown file's own links mean the
    /// file's folder, not the agent's working directory.
    func resolved(against directory: String?) -> LocalFileLink {
        guard let directory, !path.hasPrefix("/"), !path.hasPrefix("~") else { return self }
        let joined = ((directory as NSString).appendingPathComponent(path) as NSString).standardizingPath
        return LocalFileLink(path: joined, line: line, kind: kind)
    }

    static func kind(of path: String) -> Kind? {
        let name = (path as NSString).lastPathComponent
        // A dotfile (`.gitignore`) has no extension by Foundation's rule; its name is one.
        var ext = (name as NSString).pathExtension.lowercased()
        if ext.isEmpty, name.hasPrefix(".") { ext = String(name.dropFirst()).lowercased() }
        if markdown.contains(ext) { return .markdown }
        if images.contains(ext) { return .image }
        if prose.contains(ext) { return .text(code: false) }
        if code.contains(ext) || codeNames.contains(name) { return .text(code: true) }
        if proseNames.contains(name.uppercased()) { return .text(code: false) }
        return nil
    }

    private static let markdown: Set<String> = ["md", "markdown", "mdown", "mkd", "mdx"]
    private static let images: Set<String> = ["png", "jpg", "jpeg", "gif", "heic", "heif", "webp", "tif", "tiff", "bmp"]
    private static let prose: Set<String> = ["txt", "text", "log", "out", "csv", "tsv", "rst", "adoc", "org"]
    private static let code: Set<String> = [
        "swift", "m", "mm", "h", "hpp", "c", "cc", "cpp", "cs", "rs", "go", "zig", "py", "rb", "js",
        "jsx", "mjs", "cjs", "ts", "tsx", "vue", "svelte", "java", "kt", "kts", "scala", "dart", "php",
        "lua", "ex", "exs", "erl", "hs", "ml", "clj", "el", "r", "pl", "sh", "bash", "zsh", "fish",
        "sql", "json", "jsonl", "ndjson", "yaml", "yml", "toml", "ini", "cfg", "conf", "env", "xml",
        "plist", "entitlements", "xcconfig", "strings", "html", "htm", "css", "scss", "svg", "tf",
        "tfvars", "hcl", "proto", "graphql", "gradle", "patch", "diff", "lock", "resolved", "mod", "sum",
        "gitignore", "gitattributes", "editorconfig", "dockerignore",
    ]
    private static let codeNames: Set<String> = [
        "Makefile", "Dockerfile", "Gemfile", "Podfile", "Procfile", "Brewfile", "Justfile", "justfile",
        "Rakefile", "Vagrantfile", "CODEOWNERS",
    ]
    private static let proseNames: Set<String> = ["LICENSE", "README", "NOTICE", "AUTHORS", "CHANGELOG", "COPYING"]
}

/// What a file viewer needs from the fleet: a byte range of a file, or why not.
@MainActor
protocol FileReading: AnyObject {
    func readFile(
        session: UUID, path: String, offset: Int64, limit: Int, maxPixel: Int?,
        then completion: @escaping (Result<WireFileChunk, FleetRequestError>) -> Void
    )
}

extension EnvironmentValues {
    /// Set once at the navigation root, so every screen that draws a transcript can open its
    /// file links without each being handed the fleet.
    @Entry var fileReader: (any FileReading)? = nil
}

/// One pushed file viewer.
struct FileRoute: Hashable, Identifiable {
    let session: UUID
    let link: LocalFileLink
    var id: Self { self }
}

/// Opens file links in-app: an `openURL` that claims every `LocalFileLink` and pushes a
/// `FileViewerScreen`, and hands everything else back to the system untouched.
///
/// **Applied per screen rather than once at the root**, because a pushed destination's
/// `openURL` is not reliably the one set around the view that declared it, and because a
/// markdown file's own links resolve against that file's folder (`directory`), which only the
/// viewer showing it knows.
struct FileLinkRouting: ViewModifier {
    let session: UUID?
    var directory: String? = nil
    @State private var route: FileRoute?
    @Environment(\.fileReader) private var reader

    func body(content: Content) -> some View {
        content
            .environment(\.openURL, OpenURLAction { url in
                guard let session, reader != nil, let link = LocalFileLink(url) else { return .systemAction }
                route = FileRoute(session: session, link: link.resolved(against: directory))
                return .handled
            })
            .navigationDestination(item: $route) { route in
                if let reader {
                    FileViewerScreen(route: route, reader: reader)
                }
            }
    }
}

extension View {
    func opensFileLinks(session: UUID?, directory: String? = nil) -> some View {
        modifier(FileLinkRouting(session: session, directory: directory))
    }
}
