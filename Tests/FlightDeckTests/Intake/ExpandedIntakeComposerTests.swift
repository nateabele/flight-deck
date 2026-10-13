import AppKit
import SwiftUI
import XCTest
@testable import FlightDeck

/// The expanded composer: its draft reaches `intent` on every keystroke (Triage and collapse
/// read it at once), and the offscreen pictures for design review — skipped unless
/// `FD_COMPOSER_RENDER_DIR` names an output directory.
@MainActor
final class ExpandedIntakeComposerTests: XCTestCase {
    private static let sample = """
    # Add a dark mode

    Make the **settings pane** follow the system appearance, and keep `theme.json` as the override.

    - Respect the system setting on launch
    - Let the user pin light or dark
    - *Never* flash the wrong theme

    ## Notes

    1. Start with the sidebar
    2. Then the editor
    """

    private final class Draft: ObservableObject { @Published var text = "" }

    private struct Host: View {
        @ObservedObject var draft: Draft
        var body: some View {
            ExpandedIntakeComposer(intent: Binding(get: { draft.text }, set: { draft.text = $0 }),
                                   onTriage: {}, onCollapse: {})
        }
    }

    private func textView(in view: NSView) -> PlanNSTextView? {
        if let found = view as? PlanNSTextView { return found }
        return view.subviews.lazy.compactMap { self.textView(in: $0) }.first
    }

    func testTheInlineStyleIsThePlanThemeScaledToTheOldEditorsBody() {
        let inline = ComposerStyle.inline.theme
        XCTAssertEqual(inline.body.pointSize, 13, accuracy: 0.001)
        let plan = PlanTheme.standard
        let factor = inline.body.pointSize / plan.body.pointSize
        // Except its headings: a scaled `#` (about 21 pt) outweighed the request in the list's
        // box, so they step only a little above the body, largest first.
        XCTAssertEqual(inline.headingSizes, [16, 15, 14, 13, 13, 13])
        XCTAssertEqual(ComposerStyle.expanded.theme.headingSizes, plan.headingSizes, "the main view keeps the plan's headings")
        XCTAssertEqual(inline.mono.pointSize, plan.mono.pointSize * factor, accuracy: 0.001)
        XCTAssertEqual(ComposerStyle.expanded.theme.body.pointSize, plan.body.pointSize)
    }

    /// The whole box takes a click, not only its lines of text (the maintainer, 2026-10-13): the editor
    /// fills the space it is given, and a click below the last line lands in the text view.
    func testAClickBelowTheTextLandsInTheEditor() throws {
        let draft = Draft()
        draft.text = "One line"
        let host = NSHostingView(rootView: Host(draft: draft).frame(width: 700, height: 900))
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 700, height: 900),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        let view = try XCTUnwrap(textView(in: host))
        let container = try XCTUnwrap(view.superview as? PlanEditorContainer)
        XCTAssertGreaterThan(container.frame.height, view.frame.height + 200,
                             "the editor stops at its text, leaving the rest of the pane dead to clicks")
        // The container is flipped: its bottom is its bounds' maxY. `hitTest` takes the
        // superview's coordinates.
        let local = NSPoint(x: container.bounds.midX, y: container.bounds.maxY - 20)
        let below = container.superview.map { container.convert(local, to: $0) } ?? local
        XCTAssertFalse(view.frame.contains(local), "the probe point must be below the text")
        XCTAssertTrue(container.hitTest(below) === view, "a click below the text hit nothing that takes it")
    }

    func testTypingReachesTheDraftAtOnce() throws {
        let draft = Draft()
        let host = NSHostingView(rootView: Host(draft: draft).frame(width: 700, height: 500))
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 700, height: 500),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        let view = try XCTUnwrap(textView(in: host))
        window.makeFirstResponder(view)
        view.insertText("Add a ", replacementRange: view.selectedRange())
        view.insertText("dark mode", replacementRange: view.selectedRange())
        // The commit hops one main-queue turn, well inside the plan editor's two-second idle.
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(draft.text, "Add a dark mode")
        window.orderOut(nil)
    }

    /// `PlanningRender.write` snapshots the layer tree, and a plan editor that grew after its first
    /// frame leaves its text layer at the first frame's 240 pt: the picture cut off the last lines
    /// that the window itself draws. `cacheDisplay` runs the views' own drawing, as the screen does.
    private func write(_ view: some View, size: NSSize, to url: URL, appearance: NSAppearance.Name) throws {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height, alignment: .topLeading)
            .background(Color(nsColor: .windowBackgroundColor)).environment(\.controlActiveState, .key))
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: size.width, height: size.height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.contentView = host
        window.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        window.orderOut(nil)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
    }

    func testRender() throws {
        guard let dir = ProcessInfo.processInfo.environment["FD_COMPOSER_RENDER_DIR"] else {
            throw XCTSkip("set FD_COMPOSER_RENDER_DIR to render the composer PNGs")
        }
        let out = URL(fileURLWithPath: dir)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        for (appearance, tag) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            let draft = Draft()
            draft.text = Self.sample
            let binding = Binding(get: { draft.text }, set: { draft.text = $0 })
            try write(IntakeComposer(intent: binding, onTriage: {}, onExpand: {}).padding(16).frame(width: 320),
                                     size: NSSize(width: 320, height: 270),
                                     to: out.appendingPathComponent("composer-normal-\(tag).png"), appearance: appearance)
            try write(IntakeComposer(intent: binding, onTriage: {}, onCancel: {}, onExpand: {})
                .frame(width: 340).padding(14),
                                     size: NSSize(width: 368, height: 260),
                                     to: out.appendingPathComponent("composer-popover-\(tag).png"), appearance: appearance)
            try write(Host(draft: draft), size: NSSize(width: 1000, height: 700),
                                     to: out.appendingPathComponent("composer-expanded-\(tag).png"), appearance: appearance)
            try write(Host(draft: draft), size: NSSize(width: 520, height: 600),
                                     to: out.appendingPathComponent("composer-expanded-narrow-\(tag).png"), appearance: appearance)
        }
    }
}
