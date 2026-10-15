import AppKit
import SwiftUI
import XCTest
@testable import FlightDeck

/// Files dropped on a text input become their paths: the form (`DroppedPaths`), that the plan
/// editor's form is a link `PlanLinks` opens, a drop into the plan editor — at the pointer, one
/// undo step, inside a table cell without breaking the table — and the comment boxes' handler.
@MainActor
final class DroppedPathsTests: XCTestCase {
    private var root: URL!
    private var project: String { root.path }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("DroppedPathsTests-\(UUID())", isDirectory: true)
            .resolvingSymlinksInPath()
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("Sources/App"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("My Docs"), withIntermediateDirectories: true)
        for file in ["Sources/App/Foo.swift", "My Docs/Read me (v2).md", "Sources/App/50% #1: a|b.txt"] {
            try Data().write(to: root.appendingPathComponent(file))
        }
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private func url(_ relative: String) -> URL { root.appendingPathComponent(relative) }

    // MARK: Form

    func testInsideTheProjectAPathIsRelativeAndADirectoryEndsInASlash() {
        XCTAssertEqual(DroppedPaths.display(url("Sources/App/Foo.swift"), projectPath: project), "Sources/App/Foo.swift")
        XCTAssertEqual(DroppedPaths.display(url("Sources/App"), projectPath: project), "Sources/App/")
        XCTAssertEqual(DroppedPaths.display(root, projectPath: project), "./")
    }

    func testOutsideTheProjectAPathIsAbsoluteWithTildeForHome() {
        let home = NSHomeDirectory()
        XCTAssertEqual(DroppedPaths.display(URL(fileURLWithPath: home + "/Notes/a.md"), projectPath: project, isDirectory: false), "~/Notes/a.md")
        XCTAssertEqual(DroppedPaths.display(URL(fileURLWithPath: home), projectPath: project, isDirectory: true), "~/")
        XCTAssertEqual(DroppedPaths.display(URL(fileURLWithPath: "/etc/hosts"), projectPath: project, isDirectory: false), "/etc/hosts")
        XCTAssertEqual(DroppedPaths.display(URL(fileURLWithPath: "/usr/local"), projectPath: nil, isDirectory: true), "/usr/local/")
        // A sibling that merely shares the project's name as a prefix is not inside it.
        XCTAssertEqual(DroppedPaths.display(URL(fileURLWithPath: project + "-other/x.md"), projectPath: project, isDirectory: false),
                       project + "-other/x.md")
    }

    func testSeveralItemsAreCommaSeparatedOrAListOnAnEmptyLine() {
        let urls = [url("Sources/App/Foo.swift"), url("Sources/App")]
        XCTAssertEqual(DroppedPaths.markdown(urls, projectPath: project),
                       "[Sources/App/Foo.swift](Sources/App/Foo.swift), [Sources/App/](Sources/App/)")
        XCTAssertEqual(DroppedPaths.markdown(urls, projectPath: project, onEmptyLine: true),
                       "- [Sources/App/Foo.swift](Sources/App/Foo.swift)\n- [Sources/App/](Sources/App/)")
        XCTAssertEqual(DroppedPaths.markdown([urls[0]], projectPath: project, onEmptyLine: true),
                       "[Sources/App/Foo.swift](Sources/App/Foo.swift)", "one item is never a list")
    }

    func testPlainBoxesGetBarePathsAndBackticksOnlyForSpaces() {
        XCTAssertEqual(DroppedPaths.plain([url("Sources/App/Foo.swift"), url("My Docs")], projectPath: project),
                       "Sources/App/Foo.swift, `My Docs/`")
    }

    func testTheLinkTargetIsEncodedWhereRawTextWouldBreakIt() {
        let link = DroppedPaths.link(url("My Docs/Read me (v2).md"), projectPath: project)
        XCTAssertEqual(link, "[My Docs/Read me (v2).md](My%20Docs/Read%20me%20%28v2%29.md)")
    }

    // MARK: PlanLinks recognises it

    /// The dropped text parsed as the editor parses it, the link resolved as ⌘-click resolves it.
    private func resolved(_ markdown: String, at needle: String, offset: Int) throws -> PlanLinkTarget {
        let blocks = MarkdownStyler.blocks(markdown)
        let ns = markdown as NSString
        let span = try XCTUnwrap(MarkdownStyler.link(at: ns.range(of: needle).location + offset, in: blocks), "no link in \(markdown)")
        return PlanLinks.resolve(ns.substring(with: try XCTUnwrap(span.target)), projectPath: project, probe: PlanLinks.diskProbe)
    }

    func testEveryFormOfDroppedPathIsALinkThatResolvesToTheFile() throws {
        let cases: [(String, PlanLinkTarget)] = [
            ("Sources/App/Foo.swift", .edit(url("Sources/App/Foo.swift"))),
            ("My Docs/Read me (v2).md", .file(url("My Docs/Read me (v2).md"))),
            ("Sources/App/50% #1: a|b.txt", .edit(url("Sources/App/50% #1: a|b.txt"))),
            ("Sources/App", .reveal(url("Sources/App"))),
            ("My Docs", .reveal(url("My Docs"))),
        ]
        for (relative, expected) in cases {
            let markdown = "See " + DroppedPaths.link(url(relative), projectPath: project) + " now."
            XCTAssertEqual(try resolved(markdown, at: "See ", offset: 5), expected, relative)
        }
    }

    func testAnAbsolutePathOutsideTheProjectResolvesToo() throws {
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("DroppedPathsOutside-\(UUID()).txt")
        try Data().write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        let markdown = DroppedPaths.link(outside, projectPath: project)
        XCTAssertEqual(try resolved(markdown, at: "[", offset: 1), .edit(outside.standardizedFileURL))
    }

    // MARK: The plan editor

    private func fakeDrop(_ urls: [URL], at point: NSPoint, in view: NSView) -> FakeDraggingInfo {
        let board = NSPasteboard(name: NSPasteboard.Name("DroppedPathsTests-\(UUID())"))
        board.clearContents()
        board.writeObjects(urls as [NSURL])
        return FakeDraggingInfo(pasteboard: board, location: view.convert(point, to: nil), window: view.window)
    }

    private func point(of needle: String, in view: PlanNSTextView, trailing: Bool = false) throws -> NSPoint {
        let range = (view.string as NSString).range(of: needle)
        let rect = try XCTUnwrap(view.segmentRects(range).first)
        return NSPoint(x: trailing ? rect.maxX - 1 : rect.minX + 1, y: rect.midY)
    }

    func testDroppingAFileInsertsItsPathLinkAtThePointerAsOneUndoStep() throws {
        let f = PlanTableEditorTests.editor("# Plan\n\nFirst line here.\n\nSecond line.\n")
        defer { f.window.close() }
        f.view.projectPath = project
        f.window.makeFirstResponder(f.view)
        f.view.undoManager?.removeAllActions()
        let info = fakeDrop([url("Sources/App/Foo.swift")], at: try point(of: "line here", in: f.view), in: f.view)
        XCTAssertTrue(f.view.draggingEntered(info) == .copy, "a file drag shows the copy cursor")
        XCTAssertTrue(f.view.performDragOperation(info))
        let link = "[Sources/App/Foo.swift](Sources/App/Foo.swift)"
        let text = f.view.string as NSString
        let at = text.range(of: link)
        XCTAssertNotEqual(at.location, NSNotFound, f.view.string)
        XCTAssertEqual(f.view.string, "# Plan\n\nFirst " + link + "line here.\n\nSecond line.\n", "inserted where the pointer was")
        XCTAssertEqual(text.replacingOccurrences(of: link, with: ""), "# Plan\n\nFirst line here.\n\nSecond line.\n")
        XCTAssertFalse(f.view.string.contains("file://"))
        f.view.undoManager?.undo()
        XCTAssertEqual(f.view.string, "# Plan\n\nFirst line here.\n\nSecond line.\n", "one undo takes the whole drop back")
    }

    func testSeveralDroppedItemsOnAnEmptyLineAreAListOnTextTheyAreCommaSeparated() throws {
        let f = PlanTableEditorTests.editor("Intro.\n\nEnd.\n")
        defer { f.window.close() }
        f.view.projectPath = project
        f.view.setSelectedRange(NSRange(location: 7, length: 0))
        XCTAssertTrue(f.view.insertDroppedFiles([url("Sources/App/Foo.swift"), url("My Docs")]))
        XCTAssertEqual(f.view.string,
                       "Intro.\n- [Sources/App/Foo.swift](Sources/App/Foo.swift)\n- [My Docs/](My%20Docs/)\nEnd.\n")
        let g = PlanTableEditorTests.editor("Intro.\n\nEnd.\n")
        defer { g.window.close() }
        g.view.projectPath = project
        g.view.setSelectedRange(NSRange(location: 3, length: 0))
        XCTAssertTrue(g.view.insertDroppedFiles([url("Sources/App/Foo.swift"), url("My Docs")]))
        XCTAssertTrue(g.view.string.hasPrefix("Int[Sources/App/Foo.swift](Sources/App/Foo.swift), [My Docs/](My%20Docs/)ro."), g.view.string)
    }

    func testADropIntoATableCellStaysInTheCellAndKeepsTheTableValid() throws {
        let plan = "| A | B |\n|---|---|\n| one | two |\n| three | four |\n"
        let f = PlanTableEditorTests.editor(plan)
        defer { f.window.close() }
        f.view.projectPath = project
        let cell = (f.view.string as NSString).range(of: "one")
        f.view.setSelectedRange(NSRange(location: NSMaxRange(cell), length: 0))
        XCTAssertTrue(f.view.insertDroppedFiles([url("Sources/App/50% #1: a|b.txt"), url("My Docs")]))
        let rows = f.view.string.split(separator: "\n").map(String.init)
        XCTAssertEqual(rows.count, 4, "no row added or split: \(f.view.string)")
        let table = try XCTUnwrap(PlanTable.parse(Array(f.view.string.utf16)), "still a table: \(f.view.string)")
        XCTAssertEqual(table.rows.count, try XCTUnwrap(PlanTable.parse(Array(plan.utf16))).rows.count)
        XCTAssertTrue(rows[2].hasPrefix("| one[Sources/App/50% #1: a"), rows[2])
        XCTAssertTrue(rows[2].contains("](Sources/App/50%25%20%231%3A%20a%7Cb.txt), [My Docs/](My%20Docs/)"), rows[2])
        XCTAssertEqual(rows[3], "| three | four |", "the other rows are untouched")
        XCTAssertTrue(rows[2].hasSuffix("| two |"), rows[2])
        // The cell's own pipes are escaped; the encoded target carries none.
        XCTAssertTrue(rows[2].contains(#"a\|b.txt]"#), rows[2])
    }

    func testAReadOnlyEditorTakesNoDrop() throws {
        let f = PlanTableEditorTests.editor("Text.\n")
        defer { f.window.close() }
        f.view.isEditable = false
        let info = fakeDrop([url("Sources/App/Foo.swift")], at: NSPoint(x: 20, y: 20), in: f.view)
        XCTAssertTrue(f.view.draggingEntered(info) != .copy)
        XCTAssertFalse(f.view.insertDroppedFiles([url("Sources/App/Foo.swift")]))
        XCTAssertEqual(f.view.string, "Text.\n")
    }

    func testTextDragsKeepTheirHandling() throws {
        let f = PlanTableEditorTests.editor("Text.\n")
        defer { f.window.close() }
        let board = NSPasteboard(name: NSPasteboard.Name("DroppedPathsTests-\(UUID())"))
        board.clearContents()
        board.setString("https://example.com", forType: .string)
        XCTAssertNil(f.view.preferredPasteboardType(from: board.types ?? [], restrictedToTypesFrom: nil).flatMap { $0 == .fileURL ? $0 : nil })
        XCTAssertTrue(DroppedPaths.fileURLs(on: board).isEmpty)
    }

    // MARK: Comment boxes

    func testTheCommentBoxHandlerAppendsThePathsToTheEndOfTheText() {
        var text = "see"
        let done = expectation(description: "loaded")
        let binding = Binding(get: { text }, set: { text = $0 })
        let providers = [url("Sources/App/Foo.swift"), url("My Docs")].map { NSItemProvider(object: $0 as NSURL) }
        DroppedPaths.load(providers) { urls in
            binding.wrappedValue = DroppedPaths.appending(DroppedPaths.plain(urls, projectPath: self.project), to: binding.wrappedValue)
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        XCTAssertEqual(text, "see Sources/App/Foo.swift, `My Docs/`")
        XCTAssertEqual(DroppedPaths.appending("a", to: ""), "a")
        XCTAssertEqual(DroppedPaths.appending("a", to: "x "), "x a")
    }

    func testTheDraftNoteFieldAndAnswerFieldsUseTheHandler() {
        // The modifier is the one place a SwiftUI box opts in; building it must not need a window.
        var text = ""
        _ = Text("x").dropsFilePaths(into: Binding(get: { text }, set: { text = $0 }), projectPath: project)
        XCTAssertEqual(text, "")
    }
}

/// A drag the way AppKit hands one to a destination: a pasteboard and a point in window coordinates.
private final class FakeDraggingInfo: NSObject, NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    let draggingLocation: NSPoint
    let draggingDestinationWindow: NSWindow?
    init(pasteboard: NSPasteboard, location: NSPoint, window: NSWindow?) {
        draggingPasteboard = pasteboard
        draggingLocation = location
        draggingDestinationWindow = window
    }

    var draggingSourceOperationMask: NSDragOperation { [.copy, .generic] }
    var draggedImageLocation: NSPoint { draggingLocation }
    var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions, for view: NSView?, classes classArray: [AnyClass],
                                searchOptions: [NSPasteboard.ReadingOptionKey: Any], using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
    func resetSpringLoading() {}
}
