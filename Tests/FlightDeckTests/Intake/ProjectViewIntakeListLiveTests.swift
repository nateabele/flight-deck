import AppKit
import IntakeKit
import SwiftUI
import XCTest
@testable import FlightDeck

/// The Intakes list collapsing to its rail, through the real window shape — `RootView`'s
/// `NavigationSplitView`, `ProjectView`, a shaping `IntakeDetailView` with its plan editor —
/// in an offscreen titled window, as `ProjectViewInspectorLiveTests` hosts it.
///
/// Pins what the toggle must not cost: the detail pane is the same view before and after (its
/// state is keyed on the intake, never on the list), and it takes its new width ONCE — the
/// column slides over it rather than resizing it every frame of the animation, which re-laid
/// the whole detail tree per frame and restarted the plan editor's whole-plan pass on each.
@MainActor
final class ProjectViewIntakeListLiveTests: XCTestCase {
    private var root: URL!
    private var window: NSWindow?
    /// Undoes what the test wrote to `UserDefaults.standard` — see the inspector test's.
    private var restoreDefaults: (() -> Void)?

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ProjectViewIntakeListLiveTests-\(UUID())")
    }

    override func tearDown() {
        restoreDefaults?()
        window?.orderOut(nil)
        window?.contentViewController = nil
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    func testCollapseSlidesOverTheDetailAndIsRememberedPerProject() throws {
        let prefs = PreferencesStore(persistence: PreferencesStoreTests.MemoryPersistence())
        let store = SessionStore(provider: nil, persistence: SessionPersistenceTests.FakePersistence(),
                                 preferences: prefs, intakesRoot: root)
        let tag = UUID().uuidString
        store.newSession(in: URL(fileURLWithPath: "/w/list-a-\(tag)", isDirectory: true))
        store.newSession(in: URL(fileURLWithPath: "/w/list-b-\(tag)", isDirectory: true))
        let a = try XCTUnwrap(store.repos.first { $0.url.path.hasSuffix("list-a-\(tag)") })
        let b = try XCTUnwrap(store.repos.first { $0.url.path.hasSuffix("list-b-\(tag)") })
        let session = try XCTUnwrap(store.selectedSessionID)
        for repo in [a, b] {
            var settings = prefs.projectSettings(repo.url.path)
            settings.flywheelEnabled = true
            prefs.setProjectSettings(repo.url.path, settings)
            try seedShaping(project: repo.url.standardizedFileURL.path)
        }
        let service = store.intakeService
        service.pollTapes()
        restoreDefaults = {
            for repo in [a, b] {
                service.setIntakeListCollapsed(false, inProject: repo.url.path)
                service.select(nil, inProject: repo.url.path)
            }
        }
        for repo in [a, b] {
            let path = repo.url.standardizedFileURL.path
            service.select(service.intakes(forProject: path).first?.id, inProject: path)
        }
        store.selectProject(a.id)

        let window = host(RootView(store: store, preferences: prefs))
        settle(1.5)
        let editor = try XCTUnwrap(find(PlanNSTextView.self, in: try XCTUnwrap(window.contentView)))
        let settleLayout = {
            let until = Date().addingTimeInterval(3)
            while editor.layingOutWholePlan, Date() < until { self.settle(0.02) }
        }
        settleLayout()
        // The two sides mirror each other: the list's toggle on the left, the inspector's at the
        // window's far right — `.primaryAction` lands there under `NavigationSplitView`, after
        // the flexible space, measured rather than read off the placement's docs.
        let inspectorToggle = try XCTUnwrap(window.toolbar?.items.first { $0.label.hasSuffix("Inspector") }?.view)
        XCTAssertGreaterThan(inspectorToggle.convert(inspectorToggle.bounds, to: nil).maxX, window.frame.width - 24,
                             "the inspector toggle is the trailing-most toolbar item")
        let expandedWidth = editor.frame.width
        let expandedX = editor.convert(editor.bounds, to: nil).minX
        let passes = editor.fullLayoutPasses

        // With the plan focused, as ⌥⌘I is pinned: the chord must reach the toggle past the editor.
        XCTAssertTrue(window.makeFirstResponder(editor))
        XCTAssertTrue(pressListChord(in: window), "⌥⌘S must reach the list toggle past the focused editor")
        let widths = sampleWidths(of: editor, for: 0.6)
        XCTAssertTrue(service.intakeListCollapsed(forProject: a.url.path))
        XCTAssertTrue(find(PlanNSTextView.self, in: try XCTUnwrap(window.contentView)) === editor,
                      "the detail pane survived the toggle — its state is keyed on the intake, not the list")
        XCTAssertEqual(widths.count, 2, "one width change for the whole animation, not one per frame: \(widths)")
        XCTAssertEqual(widths.first, expandedWidth)
        let collapsedWidth = editor.frame.width
        // The expanded column is 320 wide, the rail 52; the detail gains what the column gave up.
        XCTAssertEqual(collapsedWidth - expandedWidth, 320 - IntakeRail.width, accuracy: 1)
        XCTAssertEqual(expandedX - editor.convert(editor.bounds, to: nil).minX, 320 - IntakeRail.width, accuracy: 1)
        settleLayout()
        XCTAssertEqual(editor.fullLayoutPasses, passes + 1, "one whole-plan pass for the one width")

        // Back out: the same, the other way.
        XCTAssertTrue(pressListChord(in: window))
        let back = sampleWidths(of: editor, for: 0.6)
        XCTAssertFalse(service.intakeListCollapsed(forProject: a.url.path))
        XCTAssertEqual(back, [collapsedWidth, expandedWidth])

        // Collapsed in A; B was never collapsed, so it reads expanded — not A's state.
        XCTAssertTrue(pressListChord(in: window))
        settle()
        store.selectProject(b.id)
        settle()
        XCTAssertFalse(service.intakeListCollapsed(forProject: b.url.path), "project B has its own list state")
        let bEditor = try XCTUnwrap(find(PlanNSTextView.self, in: try XCTUnwrap(window.contentView)))
        XCTAssertEqual(bEditor.frame.width, expandedWidth, accuracy: 1, "B's detail sits beside the expanded list")

        // A terminal tab in between tears `ProjectView` down entirely; A comes back collapsed.
        store.selectSession(session)
        settle()
        store.selectProject(a.id)
        settle(1.0)
        let aEditor = try XCTUnwrap(find(PlanNSTextView.self, in: try XCTUnwrap(window.contentView)))
        XCTAssertEqual(aEditor.frame.width, collapsedWidth, accuracy: 1, "project A's rail survived the switch")
    }

    // MARK: - Fixtures

    /// The editor's width at every turn of the run loop for `seconds` — frame by frame through
    /// the animation — as the distinct values it took, in order.
    private func sampleWidths(of view: NSView, for seconds: TimeInterval) -> [CGFloat] {
        var widths = [view.frame.width]
        let until = Date().addingTimeInterval(seconds)
        while Date() < until {
            RunLoop.current.run(until: Date().addingTimeInterval(0.004))
            if view.frame.width != widths.last { widths.append(view.frame.width) }
        }
        return widths
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
        let plan = (0..<60).map { "## \($0). Section\n\nSome words to note in section \($0), long enough to wrap at the pane's width once or twice over." }
            .joined(separator: "\n\n")
        try tapes.writeCheckpoint(Checkpoint(id: 1, stage: .draft, round: 0, major: true, createdAt: Date()),
                                  files: ["drafts/0.md": Data("# Plan\n\n\(plan)\n".utf8)], into: &tape)
        tape.status = .paused
        try tapes.saveTape(tape)
    }

    /// Titled, so SwiftUI builds a real window; parked far off any display and never made key.
    private func host(_ view: some View) -> NSWindow {
        let frame = NSRect(x: -10_000, y: -10_000, width: 1300, height: 800)
        let window = ParkedWindow(contentRect: frame, styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
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

    private func pressListChord(in window: NSWindow) -> Bool {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .option], timestamp: 0,
                                     windowNumber: window.windowNumber, context: nil, characters: "ß",
                                     charactersIgnoringModifiers: "s", isARepeat: false, keyCode: 1)
        return event.map(window.performKeyEquivalent(with:)) ?? false
    }

    private func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let match = view as? T { return match }
        for sub in view.subviews { if let match = find(type, in: sub) { return match } }
        return nil
    }
}

/// A titled window that stays where it is put: AppKit constrains a titled window's frame onto a
/// screen when it is ordered front, which brought a window "parked" at -10,000 onto the
/// human's display, bottom-left, for the length of the test.
final class ParkedWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}
