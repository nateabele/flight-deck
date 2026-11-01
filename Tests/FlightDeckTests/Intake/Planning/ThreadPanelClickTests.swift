import AppKit
import IntakeKit
import SwiftUI
import XCTest
@testable import FlightDeck

/// The thread panel's ✓ and ✗ answer a real mouse click. The smoke flow's ✓ was hit and its action
/// never ran: the diff row's border, a stroke overlay drawn on top of the row, took every click
/// meant for the buttons under it. The real panel, seeded as the UI fixture is, in a key window;
/// a mouse down and up go through the window at each control's frame (`ThreadPanelProbe`). The
/// Resolve button and an index row are calibration: they must take the same click.
@MainActor
final class ThreadPanelClickTests: XCTestCase {
    private var window: NSWindow?

    override func tearDown() {
        window?.orderOut(nil)
        window = nil
        super.tearDown()
    }

    func testTheDiffRowsAcceptAndRejectAnswerAClick() throws {
        let store = FakeThreadStore()
        let thread = store.add("Is the opening sentence right?")
        store.addTurn(thread.id, you: "Is it?", reply: "It undersells the fixture.",
                      actions: [.proposeDiff(ProposedThreadDiff(checkpoint: 2, quote: "old", replacement: "new"))])
        store.diffsByThread[thread.id] = [ThreadDiff(thread: thread.id, turn: 1, checkpoint: 2,
                                                     anchor: NoteAnchor(checkpoint: 2, quote: "old"), old: "old", new: "new")]
        var decided: [Bool] = []
        var resolved = 0
        var revealed = 0
        ThreadPanelModel.forgetSession()
        ThreadPanelProbe.frames = [:]
        let model = ThreadPanelModel(intakeID: UUID(), reader: store,
                                     actions: .init(resolve: { _ in resolved += 1; return nil },
                                                    decide: { _, _, accept, _ in decided.append(accept); return nil }))
        model.refresh()
        model.open(thread.id)

        let size = NSSize(width: 560, height: 700)
        let host = NSHostingView(rootView: ThreadPanel(model: model, withdraw: { _ in }, openCitation: { _ in },
                                                       reveal: { _ in revealed += 1 }, focusesComposer: false)
            .frame(width: size.width, height: size.height))
        let w = KeyWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        w.contentView = host
        w.makeKeyAndOrderFront(nil)
        window = w
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))

        func click(_ name: String) throws {
            // SwiftUI's global frame is in the hosting view's (flipped) space; the view converts it.
            let f = try XCTUnwrap(ThreadPanelProbe.frames[name], "\(name) never laid out")
            let point = host.convert(NSPoint(x: f.midX, y: f.midY), to: nil)
            func event(_ type: NSEvent.EventType) throws -> NSEvent {
                try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                                 timestamp: ProcessInfo.processInfo.systemUptime,
                                                 windowNumber: w.windowNumber, context: nil, eventNumber: 0,
                                                 clickCount: 1, pressure: 1))
            }
            // The up is queued first: a control that takes the down tracks the press in a loop
            // that reads the next mouse event from the queue, as it would from the window server.
            NSApp.postEvent(try event(.leftMouseUp), atStart: false)
            w.sendEvent(try event(.leftMouseDown))
            if let up = NSApp.nextEvent(matching: .leftMouseUp, until: Date(), inMode: .default, dequeue: true) {
                w.sendEvent(up)   // not taken by a tracking loop: deliver it as the server would
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        }
        try click("thread-resolve")
        XCTAssertEqual(resolved, 1, "calibration: a header button did not take the click either")
        try click("thread-index-row")
        XCTAssertEqual(revealed, 1, "calibration: an index row inside a scroll view did not take the click")
        try click("thread-diff-accept")
        XCTAssertEqual(decided, [true], "the ✓ did not run its action")
        try click("thread-diff-reject")
        XCTAssertEqual(decided, [true, false], "the ✗ did not run its action")
    }
}

/// A borderless window that can be key, as the app's window is when the panel is clicked.
private final class KeyWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}
