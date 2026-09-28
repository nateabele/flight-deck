import AppKit
import IntakeKit
import SwiftUI
import XCTest
@testable import FlightDeck

/// Renders `PlanSection` offscreen with the caret in a heading, for design review — skipped by
/// default. Set `FD_PLAN_EDITOR_RENDER` to the PNG path to write. Not an assertion test: the
/// point is to look at live preview (the caret block's `## ` shown, every other block
/// rendered) without launching the app (AGENTS.md rule 2).
final class PlanEditorRenderTests: XCTestCase {
    @MainActor
    func testRenderCaretInHeading() throws {
        guard let path = ProcessInfo.processInfo.environment["FD_PLAN_EDITOR_RENDER"] else {
            throw XCTSkip("set FD_PLAN_EDITOR_RENDER to a PNG path to render the plan editor")
        }
        let plan = """
        # Per-project font size

        Each project can override the terminal **font size**; *nil* means inherit.

        ## Settings storage

        - Store `fontSize` in `ProjectSettings`, read at surface init.
        - Fall back to the global preference — see [Preferences](https://example.com/prefs).
        1. Migrate existing sessions lazily.

        ```swift
        struct ProjectSettings { var fontSize: Double? }
        ```

        | Surface | Reads | When |
        |---|---|---|
        | Terminal | fontSize | init |
        | Sidebar preview | none | never |

        ## Testing

        Pin the fallback with a unit test.
        """
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        let tape = Tape(checkpoints: [
            Checkpoint(id: 1, stage: .draft, round: 0, major: true, createdAt: date),
            Checkpoint(id: 2, parent: 1, stage: .refine, round: 1, major: false, createdAt: date),
        ], target: .none, status: .paused)
        let load: (Int, String) -> Data? = { id, file in
            (id == 1 && file == "drafts/0.md") || (id == 2 && file == "plan.md") ? Data(plan.utf8) : nil
        }

        let size = NSSize(width: 760, height: 620)
        let root = PlanSection(intakeID: UUID(), tape: tape, loadFile: load, onSend: { _ in })
            .padding(16).frame(width: size.width, height: size.height, alignment: .topLeading)
            .background(Color(nsColor: .windowBackgroundColor))
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: size.width, height: size.height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        window.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))

        let textView = try XCTUnwrap(Self.find(NSTextView.self, in: host))
        XCTAssertEqual(textView.string, plan, "the editor holds the raw Markdown")
        XCTAssertTrue(textView.isEditable, "the head checkpoint is editable")
        window.makeFirstResponder(textView)
        let heading = (plan as NSString).range(of: "## Settings storage")
        textView.setSelectedRange(NSRange(location: NSMaxRange(heading), length: 0))
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        host.layoutSubtreeIfNeeded()

        let scale: CGFloat = 2
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale),
                                                 pixelsHigh: Int(size.height * scale), bitsPerSample: 8, samplesPerPixel: 4,
                                                 hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                                 bytesPerRow: 0, bitsPerPixel: 0))
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: rep)).cgContext
        // Bitmap contexts are bottom-left origin and the hosting view is flipped.
        context.translateBy(x: 0, y: size.height * scale)
        context.scaleBy(x: scale, y: -scale)
        try XCTUnwrap(host.layer).render(in: context)
        window.orderOut(nil)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path))
    }

    private static func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let match = view as? T { return match }
        for sub in view.subviews { if let match = find(type, in: sub) { return match } }
        return nil
    }
}
