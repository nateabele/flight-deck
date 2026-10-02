import AppKit
import IntakeKit
import SwiftUI
import XCTest
@testable import FlightDeck

/// The intake detail pane's inspector through the real window shape — `RootView`'s
/// `NavigationSplitView`, `ProjectView`'s `HSplitView` and toolbar, a shaping
/// `IntakeDetailView` with its plan editor — hosted in an offscreen titled window, so the
/// toolbar SwiftUI builds is a real `NSToolbar` and ⌥⌘I goes through the window's own
/// key-equivalent dispatch. The toggle's label ("Show Inspector" / "Hide Inspector") is what
/// reads the state back, the way the human reads it.
///
/// Pins the two reported bugs: the inspector (the notes rail, with the plan focused) must
/// close from ⌥⌘I while the plan editor holds focus, and stay closed; and its open state is
/// per project and survives the detail column showing something else in between — it was
/// `ProjectView` `@State`, which a switch away and back reset.
@MainActor
final class ProjectViewInspectorLiveTests: XCTestCase {
    private var root: URL!
    private var window: NSWindow?
    /// Undoes what the test wrote to `UserDefaults.standard`: `SessionStore` builds its
    /// `IntakeService` on the standard domain, with no seam to hand it a scratch suite.
    private var restoreDefaults: (() -> Void)?

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ProjectViewInspectorLiveTests-\(UUID())")
    }

    override func tearDown() {
        restoreDefaults?()
        window?.orderOut(nil)
        window?.contentViewController = nil
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    func testInspectorClosesFromTheEditorAndIsRememberedPerProject() throws {
        let (store, a, b, session, window) = try openTwoShapingProjects()
        XCTAssertEqual(toggleLabel(in: window), "Show Inspector", "hidden by default (spec §3)")

        // Into the plan, as a click would: the plan focused is what puts the notes rail in the
        // inspector, and the editor holding focus is where ⌥⌘I has to still work.
        let editor = try XCTUnwrap(find(PlanNSTextView.self, in: try XCTUnwrap(window.contentView)))
        XCTAssertTrue(window.makeFirstResponder(editor))
        XCTAssertTrue(pressInspectorChord(in: window))
        settle()
        XCTAssertEqual(toggleLabel(in: window), "Hide Inspector")
        XCTAssertEqual(inspectorCollapsed(in: window), false)
        XCTAssertTrue(window.firstResponder === editor, "the chord was sent with the editor focused")

        // Pressed while the column is still opening (it takes about a second here) — the case
        // the close was lost in. Settled long enough for the open, then the close, to finish.
        XCTAssertTrue(pressInspectorChord(in: window), "⌥⌘I must reach the toolbar toggle past the focused editor")
        settle(2.0)
        XCTAssertEqual(toggleLabel(in: window), "Show Inspector", "closed, and nothing reopened it")
        XCTAssertEqual(inspectorCollapsed(in: window), true, "the panel itself collapsed, not just the label")

        // Open in A; B was never opened, so it reads closed — not A's state.
        XCTAssertTrue(pressInspectorChord(in: window))
        settle()
        XCTAssertEqual(toggleLabel(in: window), "Hide Inspector")
        store.selectProject(b.id)
        settle()
        XCTAssertEqual(toggleLabel(in: window), "Show Inspector", "project B has its own inspector state")

        // A terminal tab in between tears `ProjectView` down entirely; A comes back open.
        store.selectSession(session)
        settle()
        XCTAssertNil(toggleLabel(in: window), "no toggle while a terminal fills the detail column")
        store.selectProject(a.id)
        settle()
        XCTAssertEqual(toggleLabel(in: window), "Hide Inspector", "project A's open inspector survived the switch")
    }

    /// A close held for the open to finish (`IntakeDetailView.openSettle`) must not fire over a
    /// reopen pressed before it lands: the column ends open, as the toolbar says. This guards
    /// the hold's re-check and the write-back variant: on the old view, AppKit's write-back
    /// re-closed the column at once, and that collapse's late `false` undid the reopen. It is
    /// not a RED for the root cause, `.inspector` silently dropping a mid-open `false`. That
    /// drop depends on load. The test above covers it, run alone on a loaded machine.
    func testReopenWithinTheOpenWindowKeepsTheColumnOpen() throws {
        let (_, _, _, _, window) = try openTwoShapingProjects()
        XCTAssertTrue(pressInspectorChord(in: window))
        settle(0.3)
        XCTAssertTrue(pressInspectorChord(in: window), "close, while the column is still opening")
        settle(0.2)
        XCTAssertTrue(pressInspectorChord(in: window), "reopen, before the held close lands")
        settle(2.0)
        XCTAssertEqual(toggleLabel(in: window), "Hide Inspector")
        XCTAssertEqual(inspectorCollapsed(in: window), false, "the held close saw the reopen and stood down")
    }

    // MARK: - Fixtures

    /// Two projects, each with a shaping intake selected, A shown in a hosted `RootView`.
    private func openTwoShapingProjects() throws -> (SessionStore, Repo, Repo, UUID, NSWindow) {
        let prefs = PreferencesStore(persistence: PreferencesStoreTests.MemoryPersistence())
        let store = SessionStore(provider: nil, persistence: SessionPersistenceTests.FakePersistence(),
                                 preferences: prefs, intakesRoot: root)
        // Paths unique to this run, so nothing another run left in the standard domain reads back.
        let tag = UUID().uuidString
        store.newSession(in: URL(fileURLWithPath: "/w/inspector-a-\(tag)", isDirectory: true))
        store.newSession(in: URL(fileURLWithPath: "/w/inspector-b-\(tag)", isDirectory: true))
        let a = try XCTUnwrap(store.repos.first { $0.url.path.hasSuffix("inspector-a-\(tag)") })
        let b = try XCTUnwrap(store.repos.first { $0.url.path.hasSuffix("inspector-b-\(tag)") })
        let session = try XCTUnwrap(store.selectedSessionID)
        for repo in [a, b] {
            var settings = prefs.projectSettings(repo.url.path)
            settings.flywheelEnabled = true
            prefs.setProjectSettings(repo.url.path, settings)
            try seedShaping(project: repo.url.standardizedFileURL.path)
        }
        // Seeded before first read: the service loads its intakes once, at init.
        let service = store.intakeService
        service.pollTapes()
        restoreDefaults = {
            for repo in [a, b] {
                service.setInspectorShown(false, inProject: repo.url.path)
                service.select(nil, inProject: repo.url.path)
            }
        }
        for repo in [a, b] {
            let path = repo.url.standardizedFileURL.path
            service.select(service.intakes(forProject: path).first?.id, inProject: path)
        }
        store.selectProject(a.id)

        let window = host(RootView(store: store, preferences: prefs))
        settle()
        return (store, a, b, session, window)
    }


    private func seedShaping(project: String) throws {
        var intake = Intake(projectPath: project, intent: "Plan the thing")
        intake.state = .shaping
        intake.recommended = .featurePlan
        intake.chosenPreset = .featurePlan
        intake.roundConfig = PresetExpansion.config(for: .featurePlan, available: .defaults)
        try IntakeStore(root: root).save(intake)
        let tapes = TapeStore(intakeDirectory: IntakeStore(root: root).directory(for: intake.id))
        var tape = tapes.loadTape()
        try tapes.writeCheckpoint(Checkpoint(id: 1, stage: .draft, round: 0, major: true, createdAt: Date()),
                                  files: ["drafts/0.md": Data("# Plan\n\nSome words to note.\n".utf8)], into: &tape)
        tape.status = .paused
        try tapes.saveTape(tape)
    }

    /// Titled, so SwiftUI builds a real `NSToolbar`; parked far off any display and never made
    /// key, so it steals no focus from whoever is typing.
    private func host(_ view: some View) -> NSWindow {
        let frame = NSRect(x: -10_000, y: -10_000, width: 1000, height: 700)
        let window = NSWindow(contentRect: frame, styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: view)
        window.setFrame(frame, display: true)
        window.orderFrontRegardless()
        self.window = window
        return window
    }

    private func settle(_ seconds: TimeInterval = 0.6) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    /// ⌥⌘I as the window receives it: `performKeyEquivalent` is the path a key-equivalent chord
    /// takes before any first responder's `keyDown`.
    private func pressInspectorChord(in window: NSWindow) -> Bool {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .option], timestamp: 0,
                                     windowNumber: window.windowNumber, context: nil, characters: "ˆ",
                                     charactersIgnoringModifiers: "i", isARepeat: false, keyCode: 34)
        return event.map(window.performKeyEquivalent(with:)) ?? false
    }

    private func toggleLabel(in window: NSWindow) -> String? {
        window.toolbar?.items.map(\.label).first { $0.hasSuffix("Inspector") }
    }

    /// The inspector column as AppKit holds it — what the human sees, whatever the binding says.
    private func inspectorCollapsed(in window: NSWindow) -> Bool? {
        func controllers(_ view: NSView) -> [NSSplitViewController] {
            ((view.nextResponder as? NSSplitViewController).map { [$0] } ?? []) + view.subviews.flatMap(controllers)
        }
        guard let content = window.contentView else { return nil }
        let all = controllers(content)
        return all.flatMap(\.splitViewItems).first { $0.behavior == .inspector }?.isCollapsed
    }

    private func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let match = view as? T { return match }
        for sub in view.subviews { if let match = find(type, in: sub) { return match } }
        return nil
    }
}
