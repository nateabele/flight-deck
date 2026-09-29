import AppKit
import XCTest
@testable import FlightDeck

/// What ⌘-click on a plan link does: the resolution table over a fake file system (nothing on
/// disk is touched, nothing is opened), then the editor itself — ⌘-click opens through the
/// opener seam, a plain click never does, ⌘-hover underlines and names the target.
final class PlanLinksTests: XCTestCase {
    private let project = "/Users/me/fieldOS"
    private let home = NSHomeDirectory()

    /// The fake disk: files, one executable, directories.
    private func probe(_ path: String) -> PlanLinks.Entry? {
        switch path {
        case "/Users/me/fieldOS/README.md", "/Users/me/fieldOS/docs/x.md", "/Users/me/fieldOS/src/a.ts",
             "/Users/me/fieldOS/Sources/App.swift", "/abs/notes.txt", home + "/plans/p.md", "/Users/me/fieldOS/scripts/deploy.sh",
             "/Users/me/fieldOS/wipe.command", "/Users/me/fieldOS/My File.md":
            return .file(executable: false)
        case "/Users/me/fieldOS/bin/tool": return .file(executable: true)
        case "/Users/me/fieldOS/docs", "/Applications/Evil.app": return .directory
        default: return nil
        }
    }

    private func resolve(_ raw: String, project: String? = "/Users/me/fieldOS") -> PlanLinkTarget {
        PlanLinks.resolve(raw, projectPath: project, probe: probe)
    }

    private func file(_ path: String) -> PlanLinkTarget { .file(URL(fileURLWithPath: path)) }
    private func reveal(_ path: String) -> PlanLinkTarget { .reveal(URL(fileURLWithPath: path)) }

    func testWebSchemesOpenInTheBrowser() {
        XCTAssertEqual(resolve("https://example.com/a?b=1#c"), .web(URL(string: "https://example.com/a?b=1#c")!))
        XCTAssertEqual(resolve("http://x.y"), .web(URL(string: "http://x.y")!))
        XCTAssertEqual(resolve("mailto:ops@example.com"), .web(URL(string: "mailto:ops@example.com")!))
        XCTAssertEqual(resolve("<https://example.com>"), .web(URL(string: "https://example.com")!), "autolink brackets")
        XCTAssertEqual(resolve("https://example.com \"The title\""), .web(URL(string: "https://example.com")!), "a link title is not the target")
    }

    func testFilePathsResolve() {
        XCTAssertEqual(resolve("/abs/notes.txt"), edit("/abs/notes.txt"), "absolute")
        XCTAssertEqual(resolve("~/plans/p.md"), file(home + "/plans/p.md"), "~")
        XCTAssertEqual(resolve("file:///abs/notes.txt"), edit("/abs/notes.txt"), "file://")
        XCTAssertEqual(resolve("docs/x.md"), file("/Users/me/fieldOS/docs/x.md"), "relative to the project")
        XCTAssertEqual(resolve("./src/a.ts"), edit("/Users/me/fieldOS/src/a.ts"), "./relative")
        XCTAssertEqual(resolve("docs/../README.md"), file("/Users/me/fieldOS/README.md"), "dot-dot standardized")
        XCTAssertEqual(resolve("My%20File.md"), file("/Users/me/fieldOS/My File.md"), "percent-encoded")
    }

    func testLineAndAnchorSuffixesAreStripped() {
        XCTAssertEqual(resolve("Sources/App.swift:42"), edit("/Users/me/fieldOS/Sources/App.swift"), ":line")
        XCTAssertEqual(resolve("Sources/App.swift:42:7"), edit("/Users/me/fieldOS/Sources/App.swift"), ":line:col")
        XCTAssertEqual(resolve("Sources/App.swift#L42"), edit("/Users/me/fieldOS/Sources/App.swift"), "#L")
        XCTAssertEqual(resolve("Sources/App.swift#L42-L50"), edit("/Users/me/fieldOS/Sources/App.swift"), "#L range")
        XCTAssertEqual(resolve("docs/x.md#setup"), file("/Users/me/fieldOS/docs/x.md"), "#fragment")
        XCTAssertEqual(resolve("/Users/me/fieldOS/README.md:3"), file("/Users/me/fieldOS/README.md"))
        XCTAssertEqual(resolve("file:///abs/notes.txt:9"), edit("/abs/notes.txt"))
        // `README.md:42` is a path and a line, never the scheme `readme.md`.
        XCTAssertNil(PlanLinks.scheme(of: "README.md:42"))
        XCTAssertNil(PlanLinks.scheme(of: "Makefile:12"))
        XCTAssertEqual(PlanLinks.scheme(of: "javascript:alert(1)"), "javascript")
    }

    private func edit(_ path: String) -> PlanLinkTarget { .edit(URL(fileURLWithPath: path)) }

    /// Source and scripts open in the default text EDITOR — their own handler may run them
    /// (Python Launcher for .py, Terminal for .command/.sh) — and are never just revealed: plan
    /// links mostly point at code, which is what the human wants to read.
    func testSourceAndScriptsOpenInTheEditor() {
        XCTAssertEqual(resolve("scripts/deploy.sh"), edit("/Users/me/fieldOS/scripts/deploy.sh"), ".sh, not Terminal")
        XCTAssertEqual(resolve("wipe.command"), edit("/Users/me/fieldOS/wipe.command"), ".command, not Terminal")
        XCTAssertEqual(resolve("src/a.ts"), edit("/Users/me/fieldOS/src/a.ts"))
        XCTAssertEqual(resolve("Sources/App.swift:42"), edit("/Users/me/fieldOS/Sources/App.swift"))
        for ext in ["py", "js", "ts", "sh", "command", "zsh", "rb", "swift", "go", "rs", "c", "json", "yaml", "toml"] {
            XCTAssertEqual(PlanLinks.kind(of: URL(fileURLWithPath: "/x/f." + ext), executable: false), .edit, ext)
        }
        XCTAssertEqual(PlanLinks.kind(of: URL(fileURLWithPath: "/x/run.sh"), executable: true), .edit, "an executable script is still text")
    }

    /// Finder is only for what can't be read as text and would run: bundles, non-text
    /// executables, installers, disk images, Terminal/Automator/AppleScript documents.
    func testDirectoriesAndRunnableBinariesAreRevealed() {
        XCTAssertEqual(resolve("docs"), reveal("/Users/me/fieldOS/docs"), "a directory shows in Finder")
        XCTAssertEqual(resolve("docs/"), reveal("/Users/me/fieldOS/docs"))
        XCTAssertEqual(resolve("bin/tool"), reveal("/Users/me/fieldOS/bin/tool"), "an executable bit, no extension: a binary")
        XCTAssertEqual(resolve("/Applications/Evil.app"), reveal("/Applications/Evil.app"))
        for ext in ["app", "pkg", "mpkg", "dmg", "terminal", "workflow", "scpt"] {
            XCTAssertEqual(PlanLinks.kind(of: URL(fileURLWithPath: "/x/f." + ext), executable: false), .reveal, ext)
        }
        for ext in ["md", "pdf", "png", "html"] {
            XCTAssertEqual(PlanLinks.kind(of: URL(fileURLWithPath: "/x/f." + ext), executable: false), .open, ext)
        }
    }

    func testMissingAndUnsupported() {
        XCTAssertEqual(resolve("docs/gone.md"), .missing("/Users/me/fieldOS/docs/gone.md"))
        XCTAssertEqual(resolve("docs/x.md", project: nil), .missing("docs/x.md"), "relative with no project to resolve against")
        XCTAssertEqual(resolve("javascript:alert(1)"), .unsupported)
        XCTAssertEqual(resolve("vscode://file/x"), .unsupported)
        XCTAssertEqual(resolve("#heading"), .unsupported, "an in-document anchor")
        XCTAssertEqual(resolve("  "), .unsupported)
    }

    func testOpenerDoesWhatTheTargetSays() {
        var opened: [URL] = [], revealed: [URL] = [], beeps = 0
        var edited: [URL] = []
        let opener = PlanLinkOpener(open: { opened.append($0) }, edit: { edited.append($0) }, reveal: { revealed.append($0) },
                                    beep: { beeps += 1 }, probe: { _ in nil })
        opener.perform(.web(URL(string: "https://x.y")!))
        opener.perform(file("/a.md"))
        opener.perform(edit("/s.py"))
        XCTAssertEqual(edited, [URL(fileURLWithPath: "/s.py")], "a script goes to the editor, never its own handler")
        opener.perform(reveal("/d"))
        opener.perform(.missing("/gone"))
        opener.perform(.unsupported)
        XCTAssertEqual(opened, [URL(string: "https://x.y")!, URL(fileURLWithPath: "/a.md")])
        XCTAssertEqual(revealed, [URL(fileURLWithPath: "/d")])
        XCTAssertEqual(beeps, 1, "missing beeps; unsupported does nothing at all")
    }

    func testDescribeForTheHoverTip() {
        XCTAssertEqual(PlanLinks.describe(.web(URL(string: "https://x.y/a")!)), "https://x.y/a")
        XCTAssertEqual(PlanLinks.describe(file(home + "/p.md")), "~/p.md")
        XCTAssertEqual(PlanLinks.describe(.missing("/gone.md")), "Not found: /gone.md")
        XCTAssertTrue(PlanLinks.describe(reveal("/d")).hasSuffix("shows in Finder"))
    }

    // MARK: - In the editor

    @MainActor
    private final class Recorder {
        var opened: [URL] = []
        var revealed: [URL] = []
        var beeps = 0
    }

    /// A styled plan in a real TextKit 2 view in a window, its opener recording instead of opening.
    @MainActor
    private func editor(_ text: String) -> (PlanTextView.Coordinator, PlanNSTextView, NSWindow, Recorder) {
        let view = PlanTextView(text: .constant(text), editable: true, onCommit: { _ in }, incoming: nil, onShowIncoming: {})
        let coordinator = view.makeCoordinator()
        let container = PlanEditorContainer(onShow: {})
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 700, height: 400), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        container.frame = NSRect(x: 0, y: 0, width: 700, height: 400)
        window.contentView = container
        coordinator.textView = container.textView
        container.textView.delegate = coordinator
        container.textView.textStorage?.delegate = coordinator
        coordinator.load(text)
        container.layoutSubtreeIfNeeded()
        container.textView.displayIfNeeded()
        window.makeFirstResponder(container.textView)
        let recorder = Recorder()
        container.textView.projectPath = project
        container.textView.linkOpener = PlanLinkOpener(open: { recorder.opened.append($0) }, reveal: { recorder.revealed.append($0) },
                                                       beep: { recorder.beeps += 1 }, probe: probe)
        return (coordinator, container.textView, window, recorder)
    }

    /// The middle of `word`'s glyphs, in view coordinates — laid out as a display would, since
    /// a caret move restyles the blocks it leaves and enters.
    @MainActor
    private func point(of word: String, in view: PlanNSTextView) -> NSPoint {
        view.textLayoutManager?.textViewportLayoutController.layoutViewport()
        view.displayIfNeeded()
        let range = (view.string as NSString).range(of: word)
        let rect = view.segmentRects(range).first!
        return NSPoint(x: rect.midX, y: rect.midY)
    }

    @MainActor
    private func mouse(_ type: NSEvent.EventType, at point: NSPoint, in view: NSView, command: Bool, window: NSWindow) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: command ? [.command] : [],
                           timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                           eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    @MainActor
    private func click(_ view: PlanNSTextView, at point: NSPoint, command: Bool, window: NSWindow) {
        // AppKit's own click tracks the mouse until the up: queue it first, so the loop ends. A
        // ⌘-click on a link never reaches it, so its up is drained here.
        window.postEvent(mouse(.leftMouseUp, at: point, in: view, command: command, window: window), atStart: false)
        view.mouseDown(with: mouse(.leftMouseDown, at: point, in: view, command: command, window: window))
        while window.nextEvent(matching: .leftMouseUp, until: .distantPast, inMode: .default, dequeue: true) != nil {}
    }

    /// ⌘-click on a Markdown link opens its target — read from the parse, though `(docs/x.md)` is
    /// hidden off the caret block. A plain click on the same text places the caret and opens
    /// nothing: this is an editor.
    @MainActor
    func testCommandClickOpensAndAPlainClickPlacesTheCaret() {
        let text = "# Plan\n\nSee [the doc](docs/x.md) and https://example.com/a. Then [gone](nope.md).\n\nEnd."
        let (coordinator, view, window, recorder) = editor(text)
        defer { coordinator.timer?.invalidate(); window.close() }

        // Through AppKit's own click tracking (which a synthesized click can't fully drive —
        // where the caret lands is checked through `linkClicked` below).
        click(view, at: point(of: "the doc", in: view), command: false, window: window)
        XCTAssertEqual(recorder.opened, [], "a plain click never navigates")

        // AppKit's link click without ⌘ places the caret where the click was; with ⌘, or with no
        // mouse event at all (VoiceOver's press), it opens.
        let doc = (text as NSString).range(of: "the doc")
        let over = point(of: "the doc", in: view)
        view.linkClicked(at: doc.location + 2, event: mouse(.leftMouseUp, at: over, in: view, command: false, window: window))
        XCTAssertEqual(recorder.opened, [])
        // Where the click was (placing it reveals the block's syntax, so the glyphs then move).
        XCTAssertEqual(view.selectedRange().length, 0)
        XCTAssertTrue(NSLocationInRange(view.selectedRange().location, NSRange(location: doc.location, length: doc.length + 1)),
                      "\(view.selectedRange())")
        view.linkClicked(at: doc.location + 2, event: mouse(.leftMouseUp, at: over, in: view, command: true, window: window))
        XCTAssertEqual(recorder.opened.count, 1)
        recorder.opened = []

        // The plain click revealed the block's syntax; ⌘-click from elsewhere, off it.
        view.setSelectedRange(NSRange(location: (text as NSString).range(of: "End").location, length: 0))
        click(view, at: point(of: "the doc", in: view), command: true, window: window)
        XCTAssertEqual(recorder.opened, [URL(fileURLWithPath: "/Users/me/fieldOS/docs/x.md")])

        click(view, at: point(of: "example.com", in: view), command: true, window: window)
        XCTAssertEqual(recorder.opened.last, URL(string: "https://example.com/a"), "bare URL, the trailing full stop left out")

        click(view, at: point(of: "gone", in: view), command: true, window: window)
        XCTAssertEqual(recorder.beeps, 1, "a missing file beeps")
        XCTAssertEqual(view.linkTip?.transient, true, "…and says so inline")
        XCTAssertEqual(view.linkTip?.label.stringValue, "Not found: /Users/me/fieldOS/nope.md")
        XCTAssertEqual(recorder.opened.count, 2)

        // ⌘-click on plain prose is AppKit's (no link, nothing opened).
        click(view, at: point(of: "Then", in: view), command: true, window: window)
        XCTAssertEqual(recorder.opened.count, 2)
    }

    /// VoiceOver's press on the AXLink arrives as `clicked(onLink:at:)` with no mouse event:
    /// it opens. The `.link` attribute is what exposes the AXLink.
    @MainActor
    func testAccessibilityPressOpensTheLink() {
        let text = "Read [the doc](docs/x.md)."
        let (coordinator, view, window, recorder) = editor(text)
        defer { coordinator.timer?.invalidate(); window.close() }
        let at = (text as NSString).range(of: "the doc").location
        XCTAssertNotNil(view.textStorage?.attribute(.link, at: at, effectiveRange: nil), "an AXLink for VoiceOver")
        view.clicked(onLink: "docs/x.md", at: at + 1)
        XCTAssertEqual(recorder.opened, [URL(fileURLWithPath: "/Users/me/fieldOS/docs/x.md")])
    }

    /// ⌘ over a link underlines it and shows where it goes; releasing ⌘ (or leaving the link)
    /// takes both away. The underline is drawn over the text: the stored plan never changes.
    @MainActor
    func testCommandHoverUnderlinesAndNamesTheTarget() {
        let text = "Read [the doc](docs/x.md) now."
        let (coordinator, view, window, _) = editor(text)
        defer { coordinator.timer?.invalidate(); window.close() }
        let over = point(of: "the doc", in: view)
        let doc = (text as NSString).range(of: "the doc")

        view.updateLinkHover(at: over, command: false)
        XCTAssertNil(view.hoveredLink, "no ⌘, no hover")
        view.updateLinkHover(at: over, command: true)
        XCTAssertEqual(view.hoveredLink, doc)
        XCTAssertEqual(view.linkTip?.label.stringValue, "/Users/me/fieldOS/docs/x.md")
        XCTAssertEqual(view.linkTip?.transient, false)
        XCTAssertEqual(view.linkUnderlines.count, 1, "underlined")
        XCTAssertEqual(view.linkUnderlines.first?.frame.minX ?? 0, view.segmentRects(doc)[0].minX, accuracy: 0.5)
        XCTAssertNil(view.textStorage?.attribute(.underlineStyle, at: doc.location + 1, effectiveRange: nil), "not in the storage")

        view.updateLinkHover(at: point(of: "now", in: view), command: true)
        XCTAssertNil(view.hoveredLink, "off the link")
        XCTAssertNil(view.linkTip)
        XCTAssertEqual(view.linkUnderlines.count, 0)

        view.updateLinkHover(at: over, command: true)
        view.updateLinkHover(at: over, command: false)
        XCTAssertNil(view.hoveredLink, "⌘ released")
        XCTAssertEqual(view.linkUnderlines.count, 0)
        XCTAssertEqual(view.string, text)
    }
}
