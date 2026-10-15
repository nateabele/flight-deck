import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Files and folders dropped on a text input become their PATHS in the text — never an
/// attachment, the file's contents, or a `file://` URL.
///
/// The form follows what a plan can link (`PlanLinks`, `MarkdownStyler`): only `[text](target)`,
/// `<scheme:…>` and bare http(s) URLs are links — a bare path or one in backticks is not — and
/// `PlanLinks.resolve` reads a target as an absolute path, `~/…`, or a path relative to the
/// intake's project. So the plan editor gets `[Sources/App/Foo.swift](Sources/App/Foo.swift)`,
/// whose target is percent-encoded where raw text would end or misread the link (see `encode`),
/// and the plain comment boxes, which don't render Markdown, get the bare path (backticked when
/// it has spaces, so it stays one token).
enum DroppedPaths {
    /// How a path reads in a plan or a comment: project-relative inside `projectPath`, else
    /// absolute with `~` for the home folder; a directory ends in `/`.
    static func display(_ url: URL, projectPath: String?, isDirectory: Bool? = nil) -> String {
        let path = url.standardizedFileURL.path
        let directory = isDirectory ?? ((try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? url.hasDirectoryPath)
        var shown = path
        if let relative = relative(path, to: projectPath) {
            shown = relative
        } else {
            let home = NSHomeDirectory()
            if path == home { shown = "~" } else if path.hasPrefix(home + "/") { shown = "~" + path.dropFirst(home.count) }
        }
        return directory && !shown.hasSuffix("/") ? shown + "/" : shown
    }

    /// `path` below `project` (symlink spellings of either compared too), "." for the project itself.
    private static func relative(_ path: String, to project: String?) -> String? {
        guard let project, !project.isEmpty else { return nil }
        func below(_ path: String, _ root: String) -> String? {
            let root = (root as NSString).standardizingPath
            if path == root { return "." }
            return path.hasPrefix(root + "/") ? String(path.dropFirst(root.count + 1)) : nil
        }
        if let found = below(path, project) { return found }
        let real = { (p: String) in URL(fileURLWithPath: p).resolvingSymlinksInPath().path }
        return below(real(path), real(project))
    }

    /// The characters a link target can't carry raw: the closing `)`, the space that starts a
    /// `"title"`, the `#` and `:digits` `PlanLinks.stripLocation` cuts, a `:` that reads as a
    /// scheme, the `|` of a table cell, and the Markdown marks a parse would claim.
    private static let unsafeInTarget = CharacterSet(charactersIn: " ()[]<>%#:|*`\"'\\?\t")

    private static func encode(_ path: String) -> String {
        path.unicodeScalars.reduce(into: "") { out, scalar in
            if unsafeInTarget.contains(scalar) || scalar.value < 0x20 {
                for byte in String(scalar).utf8 { out += String(format: "%%%02X", byte) }
            } else {
                out.unicodeScalars.append(scalar)
            }
        }
    }

    /// A Markdown link `PlanLinks` opens: the path shown as its text, encoded as its target.
    static func link(_ url: URL, projectPath: String?) -> String {
        let shown = display(url, projectPath: projectPath)
        let label = shown.replacingOccurrences(of: "[", with: "").replacingOccurrences(of: "]", with: "")
        return "[\(label)](\(encode(shown)))"
    }

    /// What goes into a Markdown plan. Several items are `, `-separated, or one `- ` list item per line when the line is empty.
    static func markdown(_ urls: [URL], projectPath: String?, onEmptyLine: Bool = false) -> String {
        let links = urls.map { link($0, projectPath: projectPath) }
        guard onEmptyLine, links.count > 1 else { return links.joined(separator: ", ") }
        return links.map { "- " + $0 }.joined(separator: "\n")
    }

    /// What goes into a plain-text comment box: the paths, `, `-separated, a path with
    /// whitespace in backticks.
    static func plain(_ urls: [URL], projectPath: String?) -> String {
        urls.map { url in
            let shown = display(url, projectPath: projectPath)
            return shown.contains(where: \.isWhitespace) ? "`\(shown)`" : shown
        }.joined(separator: ", ")
    }

    /// The file and folder URLs on a pasteboard, in drop order.
    static func fileURLs(on pasteboard: NSPasteboard) -> [URL] {
        let found = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        return found ?? []
    }

    /// The file URLs the providers carry, in order, delivered once all have loaded.
    static func load(_ providers: [NSItemProvider], completion: @escaping ([URL]) -> Void) {
        let files = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        var urls = [URL?](repeating: nil, count: files.count)
        let group = DispatchGroup()
        for (i, provider) in files.enumerated() {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                DispatchQueue.main.async {
                    urls[i] = url?.isFileURL == true ? url : nil
                    group.leave()
                }
            }
        }
        group.notify(queue: .main) { completion(urls.compactMap { $0 }) }
    }

    /// `text` with `paths` added at its end, a space between when it doesn't end in one.
    static func appending(_ paths: String, to text: String) -> String {
        guard !text.isEmpty, let last = text.last, !last.isWhitespace else { return text + paths }
        return text + " " + paths
    }
}

extension View {
    /// A plain-text input that takes dropped files and folders as their paths, added at the end
    /// of `text` (a SwiftUI field doesn't expose its caret). Anything but files drops as before.
    func dropsFilePaths(into text: Binding<String>, projectPath: String?) -> some View {
        onDrop(of: [.fileURL], isTargeted: nil) { providers in
            DroppedPaths.load(providers) { urls in
                guard !urls.isEmpty else { return }
                text.wrappedValue = DroppedPaths.appending(DroppedPaths.plain(urls, projectPath: projectPath), to: text.wrappedValue)
            }
            return true
        }
    }
}
