import AppKit
import IntakeKit
import XCTest
@testable import FlightDeck

/// The visual block in the plan as pictures, for design review against the approved render
/// (visual-block-alternates-v2.html, option B): the filmstrip, Compare, the missing and pending
/// placeholders, and a parse error, light and dark. Skipped unless `FD_PLANNING_RENDER_DIR` (or
/// `FD_INTAKE_RENDER_DIR`) is set. The block shows its pictures here, not live web views: a web
/// view's content is not in its layer, so a render of one is blank.
@MainActor
final class VisualBlockRenderTests: XCTestCase {
    private var fixture: VisualFixture!

    override func setUpWithError() throws {
        guard VisualFixture.renderDirectory != nil else { throw XCTSkip("set FD_PLANNING_RENDER_DIR to render the visual block PNGs") }
        fixture = try VisualFixture()
    }

    override func tearDown() { fixture?.remove() }

    private static func plan(_ fence: String, caption: String = "Pairing handshake: phone, Mac and hostd") -> String {
        """
        ### 3. Pairing

        The phone pairs with the Mac over SPAKE2 using a short code, so no secret ever crosses the network. Once paired, the phone keeps a session token in its Keychain, and the host records the controller's key.

        ```\(fence)
        \(caption)
        ```

        If the exchange fails, for example from a mistyped code, the phone shows the code entry again and the host's pairing window stays open until it times out.
        """
    }

    private struct Editor {
        let coordinator: PlanTextView.Coordinator
        let container: PlanEditorContainer
        let window: NSWindow
        var view: PlanNSTextView { container.textView }
    }

    private func editor(_ text: String, appearance: NSAppearance.Name, width: CGFloat = 820) -> Editor {
        let store = fixture.store
        let view = PlanTextView(text: .constant(text), editable: true, onCommit: { _ in }, incoming: nil, onShowIncoming: {}).visuals(store)
        let coordinator = view.makeCoordinator()
        let container = PlanEditorContainer(onShow: {})
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: width, height: 900), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        let backdrop = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 900))
        backdrop.wantsLayer = true
        window.contentView = backdrop
        backdrop.addSubview(container)
        window.appearance?.performAsCurrentDrawingAppearance { backdrop.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor }
        container.frame = NSRect(x: 0, y: 0, width: width, height: 900)
        coordinator.textView = container.textView
        container.textView.delegate = coordinator
        container.textView.textStorage?.delegate = coordinator
        container.textView.visualBlocks.store = store
        container.textView.visualBlocks.allowsLive = false
        coordinator.load(text)
        return Editor(coordinator: coordinator, container: container, window: window)
    }

    private func settle(_ e: Editor) {
        let until = Date().addingTimeInterval(3)
        repeat { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) } while e.view.layingOutWholePlan && Date() < until
        e.container.layoutSubtreeIfNeeded()
        e.view.visualBlocks.refresh()
    }

    /// Waits for every block's pictures, which `VisualRenderHost` draws in memory.
    private func waitForPictures(_ e: Editor) {
        let until = Date().addingTimeInterval(30)
        while Date() < until, !e.view.visualBlocks.blocks.values.allSatisfy(\.picturesReady) {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertTrue(e.view.visualBlocks.blocks.values.allSatisfy(\.picturesReady), "pictures drawn")
    }

    private func write(_ e: Editor, _ name: String, width: CGFloat = 820) throws {
        let dir = try XCTUnwrap(VisualFixture.renderDirectory)
        settle(e)
        let height = ceil(e.container.contentHeight) + 8
        e.window.setContentSize(NSSize(width: width, height: height))
        e.container.frame = NSRect(x: 0, y: 0, width: width, height: height)
        e.window.contentView?.frame = NSRect(x: 0, y: 0, width: width, height: height)
        e.window.orderFrontRegardless()
        settle(e)
        waitForPictures(e)
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        e.container.layoutSubtreeIfNeeded()
        e.window.contentView?.displayIfNeeded()
        let scale: CGFloat = 2
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width * scale), pixelsHigh: Int(height * scale),
                                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: rep)).cgContext
        context.scaleBy(x: scale, y: scale)
        try XCTUnwrap(e.window.contentView?.layer).render(in: context)
        e.window.orderOut(nil)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: dir.appendingPathComponent("\(name).png"))
    }

    private let appearances: [(String, NSAppearance.Name)] = [("light", .aqua), ("dark", .darkAqua)]

    func testRenderFilmstrip() throws {
        try fixture.pairing()
        for (mode, appearance) in appearances {
            let e = editor(Self.plan("fd-visual id=pairing-handshake"), appearance: appearance)
            defer { e.view.visualBlocks.tearDown(); e.window.close() }
            try write(e, "block-filmstrip-\(mode)")
        }
    }

    func testRenderCompare() throws {
        try fixture.pairing()
        for (mode, appearance) in appearances {
            let e = editor(Self.plan("fd-visual id=pairing-handshake"), appearance: appearance)
            defer { e.view.visualBlocks.tearDown(); e.window.close() }
            e.view.visualBlocks.onMakePrimary = { _, _ in }
            settle(e)
            let block = try XCTUnwrap(e.view.visualBlocks.blocks.values.first)
            block.setComparing(true)
            XCTAssertEqual(block.testSnapshot.compareTitle, "Done")
            try write(e, "block-compare-\(mode)")
        }
    }

    func testRenderMissingAndPending() throws {
        for (mode, appearance) in appearances {
            let missing = editor(Self.plan("fd-visual id=nowhere"), appearance: appearance)
            defer { missing.view.visualBlocks.tearDown(); missing.window.close() }
            try write(missing, "block-missing-\(mode)")
            let pending = editor(Self.plan("fd-visual id=pairing-flow pending", caption: "Pairing as a data flow"), appearance: appearance)
            defer { pending.view.visualBlocks.tearDown(); pending.window.close() }
            try write(pending, "block-pending-\(mode)")
        }
    }

    func testRenderParseErrorAndSingle() throws {
        try fixture.revision("broken", r: 1, source: VisualFixture.broken, kind: "flowchart", title: "Pairing (broken source)")
        try fixture.revision("sequence", r: 1, source: VisualFixture.sequence, kind: "sequence", title: "Pairing handshake",
                             states: ["happy", "mistyped"], sizes: ["default", "phone"])
        for (mode, appearance) in appearances {
            let broken = editor(Self.plan("fd-visual id=broken"), appearance: appearance)
            defer { broken.view.visualBlocks.tearDown(); broken.window.close() }
            try write(broken, "block-parse-error-\(mode)")
            let single = editor(Self.plan("fd-visual id=sequence"), appearance: appearance)
            defer { single.view.visualBlocks.tearDown(); single.window.close() }
            try write(single, "block-sequence-states-\(mode)")
        }
    }
}
