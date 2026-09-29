import AppKit
import UniformTypeIdentifiers

/// What a plan link's target means once resolved — what ⌘-click does with it (`PlanLinkOpener`).
enum PlanLinkTarget: Equatable {
    /// http(s) or mailto: the default browser or mail app.
    case web(URL)
    /// An existing file the default app for its type opens.
    case file(URL)
    /// Shown selected in Finder instead of opened: a directory, or a file that opening would
    /// RUN (`PlanLinks.runs`).
    case reveal(URL)
    /// A file target that isn't there (or a relative one with no project to resolve it against).
    case missing(String)
    /// Any other scheme (`javascript:`, `x-man-page:`, an in-document `#anchor`): ignored.
    case unsupported
}

/// Turns the target text of a plan link — `[t](target)`, `<target>` or a bare URL, as the
/// Markdown parse found it (`MarkdownSpan.target`) — into what ⌘-click does. Pure apart from the
/// file-system probe, which is passed in, so `PlanLinksTests` pins the table without touching disk.
///
/// Plans link to code as agents write it: absolute paths, `~/…`, `file://` URLs and paths
/// relative to the repo (`docs/x.md`, `./src/a.ts`), often with a line — `a.swift:42`,
/// `a.swift:42:7`, `a.swift#L42`. The line is stripped for resolution: "open with the default
/// app" has no portable way to pass one on.
enum PlanLinks {
    /// What the probe found at a path.
    enum Entry: Equatable { case file(executable: Bool), directory }

    static func resolve(_ raw: String, projectPath: String?, probe: (String) -> Entry?) -> PlanLinkTarget {
        var text = raw.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("<"), text.hasSuffix(">") { text = String(text.dropFirst().dropLast()) }
        // `[t](path "title")`: the title is not part of the target.
        if let space = text.firstIndex(of: " "), text[text.index(after: space)...].first.map({ "\"'(".contains($0) }) == true {
            text = String(text[..<space])
        }
        guard !text.isEmpty, !text.hasPrefix("#") else { return .unsupported }

        if let scheme = scheme(of: text) {
            switch scheme {
            case "http", "https", "mailto":
                return URL(string: text).map(PlanLinkTarget.web) ?? .unsupported
            case "file":
                guard let url = URL(string: text), url.isFileURL else { return .unsupported }
                return probed(stripLocation(url.path), probe: probe)
            default:
                return .unsupported
            }
        }

        var path = stripLocation(text)
        path = path.removingPercentEncoding ?? path
        if path.hasPrefix("~") { path = (path as NSString).expandingTildeInPath }
        if !path.hasPrefix("/") {
            guard let projectPath, !projectPath.isEmpty else { return .missing(path) }
            path = (projectPath as NSString).appendingPathComponent(path)
        }
        return probed((path as NSString).standardizingPath, probe: probe)
    }

    private static func probed(_ path: String, probe: (String) -> Entry?) -> PlanLinkTarget {
        let url = URL(fileURLWithPath: path)
        switch probe(path) {
        case nil: return .missing(path)
        case .directory: return .reveal(url)
        case .file(let executable): return executable || runs(url) ? .reveal(url) : .file(url)
        }
    }

    /// A URL scheme, lowercased — only where the text really is a URL. `README.md:42` and
    /// `Makefile:12` are a path and a line, not the schemes `readme.md` and `makefile`: a scheme
    /// with a dot or followed by only digits is read as a path.
    static func scheme(of text: String) -> String? {
        guard let colon = text.firstIndex(of: ":") else { return nil }
        let scheme = text[..<colon]
        guard let first = scheme.first, first.isASCII, first.isLetter,
              scheme.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "+-.".contains($0)) }) else { return nil }
        let rest = text[text.index(after: colon)...]
        if rest.hasPrefix("//") { return scheme.lowercased() }
        if scheme.contains(".") || (!rest.isEmpty && rest.allSatisfy { $0.isNumber || $0 == ":" }) { return nil }
        return scheme.lowercased()
    }

    /// The path without a trailing `:line[:col]`, `#L42` / `#L42-L50`, or other `#fragment`.
    static func stripLocation(_ text: String) -> String {
        var path = text
        if let hash = path.lastIndex(of: "#") { path = String(path[..<hash]) }
        // Up to two trailing `:digits` groups — line, then column.
        for _ in 0..<2 {
            guard let colon = path.lastIndex(of: ":") else { break }
            let tail = path[path.index(after: colon)...]
            guard !tail.isEmpty, tail.allSatisfy(\.isNumber) else { break }
            path = String(path[..<colon])
        }
        return path
    }

    /// Whether opening the file with its default app would RUN it rather than show it: an app
    /// or bundle, a script (a `.command` or `.sh` opens in Terminal and runs; a `.py` can open
    /// in Python Launcher, which runs it), an installer, or a location file that forwards to
    /// something else. A plan is text an agent wrote, so its link is untrusted: ⌘-click on
    /// `[notes](./scripts/wipe.command)` must not be how a plan executes code on the human's
    /// Mac. These are revealed in Finder instead — the human can still open them, on purpose.
    static func runs(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if runnableExtensions.contains(ext) { return true }
        guard !ext.isEmpty, let type = UTType(filenameExtension: ext) else { return false }
        return [UTType.executable, .script, .application, .applicationBundle, .package, .unixExecutable]
            .contains { type.conforms(to: $0) }
    }

    /// Extensions `runs` treats as runnable whatever their declared type says — some have no
    /// declared type on a given Mac, and a missing declaration must not make them openable.
    static let runnableExtensions: Set<String> = [
        "app", "command", "tool", "sh", "bash", "zsh", "csh", "ksh", "tcsh", "fish", "py", "pyw", "rb", "pl", "php",
        "scpt", "scptd", "applescript", "workflow", "action", "terminal", "jar", "pkg", "mpkg", "exe", "bat",
        "webloc", "inetloc", "fileloc", "url", "prefpane", "saver", "shortcut", "osax", "kext", "plugin", "bundle",
    ]

    /// The real file system: what is at `path`, and whether a file there is executable.
    static func diskProbe(_ path: String) -> Entry? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { return nil }
        return isDirectory.boolValue ? .directory : .file(executable: FileManager.default.isExecutableFile(atPath: path))
    }

    /// The line the ⌘-hover tip shows: where the link goes, the home directory as `~`.
    static func describe(_ target: PlanLinkTarget) -> String {
        func short(_ path: String) -> String { (path as NSString).abbreviatingWithTildeInPath }
        switch target {
        case .web(let url): return url.absoluteString
        case .file(let url): return short(url.path)
        case .reveal(let url): return short(url.path) + " — shows in Finder"
        case .missing(let path): return "Not found: " + short(path)
        case .unsupported: return "This link can't be opened"
        }
    }
}

/// Does what a resolved link says, through injectable effects: tests never open a browser, an
/// editor or Finder.
struct PlanLinkOpener {
    var open: (URL) -> Void = { NSWorkspace.shared.open($0) }
    var reveal: (URL) -> Void = { NSWorkspace.shared.activateFileViewerSelecting([$0]) }
    var beep: () -> Void = { NSSound.beep() }
    var probe: (String) -> PlanLinks.Entry? = PlanLinks.diskProbe

    /// Returns what it did, so the editor can show the missing-file notice.
    @discardableResult
    func perform(_ target: PlanLinkTarget) -> PlanLinkTarget {
        switch target {
        case .web(let url), .file(let url): open(url)
        case .reveal(let url): reveal(url)
        case .missing: beep()
        case .unsupported: break
        }
        return target
    }
}

/// The small label under a link: where it goes while ⌘ is held over it, or "Not found: …" for
/// a moment after a ⌘-click on a file that isn't there — inline and non-modal, never an alert
/// over the plan. A subview of the text view, so it scrolls with the link; it never takes the
/// mouse, so the pointer that summoned it keeps hovering the link.
final class PlanLinkTip: NSView {
    /// The missing-file notice, which times out; the hover tip goes when the hover does.
    let transient: Bool
    let label: NSTextField

    init(text: String, transient: Bool) {
        self.transient = transient
        label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11.5)
        label.textColor = transient ? .labelColor : .secondaryLabelColor
        label.lineBreakMode = .byTruncatingMiddle
        label.maximumNumberOfLines = 1
        label.translatesAutoresizingMaskIntoConstraints = false
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 5
        layer?.borderWidth = 1
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
            label.widthAnchor.constraint(lessThanOrEqualToConstant: 520),
        ])
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Colours by the current appearance, re-read when it changes (a layer's CGColor doesn't follow).
    override func updateLayer() {
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        layer?.borderColor = NSColor.separatorColor.cgColor
    }

    override var wantsUpdateLayer: Bool { true }
}

/// One line segment of the ⌘-hover underline, in the link's tint. Never takes the mouse.
final class PlanLinkUnderline: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = PlanTheme.standard.link.cgColor }
}
