import AppKit
import Combine
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
/// Pins the two reported bugs: the inspector (opened with the plan focused) must
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
        // With every display asleep AppKit never finishes the column's open animation, so
        // `.inspector` drops every later `false`, even one sent 3 s after the open. Measured
        // 2026-10-09 on unchanged code back to 61e58016: 3 of 3 passes with the displays
        // awake, a failure at the "panel itself collapsed" check on every run with them asleep.
        // So an unattended suite run went red overnight. The human can't press ⌥⌘I at a dark
        // screen, so it is no product bug. A skip, not a looser check: this test is the only
        // guard on the close race, and only an awake display can show whether it holds.
        try XCTSkipIf(Self.everyDisplayAsleep(),
                      "every display is asleep: AppKit's column animation never completes, so the close can't be judged")
        let (store, a, b, session, window) = try openTwoShapingProjects()
        XCTAssertEqual(toggleLabel(in: window), "Show Inspector", "hidden by default (spec §3)")

        // Into the plan, as a click would: the editor holding focus is where ⌥⌘I has to still
        // work. Focus no longer picks the inspector's content (its mode does), so this is also
        // where the old focus-driven swap to the notes rail would show.
        let editor = try XCTUnwrap(find(PlanNSTextView.self, in: try XCTUnwrap(window.contentView)))
        XCTAssertTrue(window.makeFirstResponder(editor))
        XCTAssertTrue(pressInspectorChord(in: window))
        settle()
        XCTAssertEqual(toggleLabel(in: window), "Hide Inspector")
        XCTAssertEqual(inspectorCollapsed(in: window), false)
        XCTAssertTrue(window.firstResponder === editor, "the chord was sent with the editor focused")
        // The mode control is there, still on Rounds (a paused Feature plan's default), with the
        // plan focused: the focus that used to hand the column to the notes rail moves nothing.
        let modes = try XCTUnwrap(all(NSSegmentedControl.self, in: try XCTUnwrap(window.contentView)).first { control in
            (0..<control.segmentCount).map { control.label(forSegment: $0) } == ["Notes", "Rounds"]
        }, "the inspector's Notes/Rounds control")
        XCTAssertEqual(modes.segmentCount, 2)
        XCTAssertEqual(modes.label(forSegment: modes.selectedSegment), "Rounds")

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

    /// A Notes/Rounds switch redraws the inspector and nothing around it. Before, the mode lived
    /// in a `@Published` on `IntakeService`, which `SessionStore` forwards, so each click
    /// re-evaluated `RootView`, `ProjectView`, the detail pane and its live card (measured on
    /// `4e13c49d`: root 1, project 1, detail 2, live card 2 per switch).
    ///
    /// The window's own clock (tape polls, the live card's ticks) still publishes now and then,
    /// and under a loaded suite one landed inside a sample. So a sample counts only when
    /// `SessionStore` published nothing while it settled; a publish made by the click itself
    /// (the old code's, synchronous in `sendAction`) does not disqualify it, so this still fails
    /// against `4e13c49d`.
    func testAModeSwitchRedrawsTheInspectorAlone() throws {
        let (store, _, _, _, window) = try openTwoShapingProjects()
        XCTAssertTrue(pressInspectorChord(in: window))
        settle(1.5)
        let modes = try XCTUnwrap(all(NSSegmentedControl.self, in: try XCTUnwrap(window.contentView)).first { control in
            (0..<control.segmentCount).map { control.label(forSegment: $0) } == ["Notes", "Rounds"]
        }, "the inspector's Notes/Rounds control")
        XCTAssertEqual(modes.label(forSegment: modes.selectedSegment), "Rounds")

        var background = 0
        let sub = store.objectWillChange.sink { _ in background += 1 }
        defer { sub.cancel() }
        var clean: [[String: Int]] = []
        for segment in [0, 1, 0, 1, 0, 1, 0, 1] {
            RenderProbe.reset()
            modes.selectedSegment = segment
            XCTAssertTrue(modes.sendAction(modes.action, to: modes.target), "the control's click reaches SwiftUI")
            background = 0
            spinRunLoop { (RenderProbe.counts["inspector"] ?? 0) > 0 }
            settle(0.3)
            XCTAssertEqual(modes.label(forSegment: modes.selectedSegment), ["Notes", "Rounds"][segment])
            if background == 0 { clean.append(RenderProbe.counts) }
        }
        XCTAssertGreaterThanOrEqual(clean.count, 3, "too few switches free of the window's own publishes")
        for (step, count) in clean.enumerated() {
            XCTAssertGreaterThan(count["inspector"] ?? 0, 0, "switch \(step) redrew the inspector: \(count)")
            for part in ["root", "project", "detail", "liveCard", "header", "plan"] {
                XCTAssertEqual(count[part] ?? 0, 0, "switch \(step) redrew \(part): \(count)")
            }
        }
    }

    /// Opening the inspector settles: the window stops re-evaluating, and every column still has
    /// content. The maintainer's 2026-10-09 screenshot after ⌥⌘I showed the sidebar, the Intakes list and
    /// the inspector as blank panes with only the plan drawn — the main thread busy redrawing.
    func testOpeningTheInspectorSettlesWithEveryColumnDrawn() throws {
        let (_, _, _, _, window) = try openTwoShapingProjects()
        XCTAssertTrue(pressInspectorChord(in: window))
        settleRenders()
        RenderProbe.reset()
        settle(2.0)
        let idle = RenderProbe.counts
        for part in ["root", "project", "detail", "inspector", "header", "plan"] {
            XCTAssertLessThanOrEqual(idle[part] ?? 0, 1, "\(part) kept re-evaluating with nothing changing: \(idle)")
        }
        let content = try XCTUnwrap(window.contentView)
        let inspector = try XCTUnwrap(all(NSSegmentedControl.self, in: content).first { control in
            (0..<control.segmentCount).map { control.label(forSegment: $0) } == ["Notes", "Rounds"]
        }, "the inspector's Notes/Rounds control")
        XCTAssertGreaterThan(inspector.frame.width, 0)
        XCTAssertNotNil(inspector.window, "the control is in the window")
        // The sidebar's and the Intakes list's rows are still there beside it.
        let lists = all(NSTableView.self, in: content).filter { $0.numberOfRows > 0 && $0.visibleRect.height > 0 }
        XCTAssertGreaterThanOrEqual(lists.count, 2, "sidebar and Intakes list both drawn: \(lists.map(\.numberOfRows))")
    }

    /// The Notes mode must not set the window's minimum height. SwiftUI sizes a window's minimum
    /// from its content measured at a zero proposal, and at zero width every line of the rail's
    /// vertically fixed-size text wrapped a character at a time: the footer alone came to 618 pt,
    /// each unplaced note card to hundreds more. The window was then held taller than it was —
    /// grown here, and on a screen that could not grow it (a tiled or full-screen window) laid
    /// out taller than itself and anchored at the bottom, so every column's top was cut off:
    /// the sidebar, the Intakes list and the inspector showed empty panes and the plan could
    /// not scroll to its top (the maintainer, 2026-10-11, on `118e6db0`). Measured before the fix: a
    /// 700 pt window grew to 833 pt with no notes, and its minimum height went 349 → 833.
    func testTheNotesRailLeavesTheWindowItsHeight() throws {
        let (_, _, _, _, window) = try openTwoShapingProjects(pendingNotes: 3)
        XCTAssertTrue(pressInspectorChord(in: window))
        settle(1.5)
        let rounds = window.contentMinSize.height
        let modes = try XCTUnwrap(all(NSSegmentedControl.self, in: try XCTUnwrap(window.contentView)).first { control in
            (0..<control.segmentCount).map { control.label(forSegment: $0) } == ["Notes", "Rounds"]
        }, "the inspector's Notes/Rounds control")
        modes.selectedSegment = 0
        XCTAssertTrue(modes.sendAction(modes.action, to: modes.target))
        settle(1.5)
        XCTAssertEqual(modes.label(forSegment: modes.selectedSegment), "Notes")
        XCTAssertLessThanOrEqual(window.contentMinSize.height, rounds + 1,
                                 "the rail raised the window's minimum height: \(rounds) on Rounds, \(window.contentMinSize.height) on Notes")
        XCTAssertEqual(window.frame.height, 700, accuracy: 0.5, "the window was grown to fit the rail")
    }

    // MARK: - Fixtures

    /// Two projects, each with a shaping intake selected, A shown in a hosted `RootView`.
    private func openTwoShapingProjects(pendingNotes: Int = 0) throws -> (SessionStore, Repo, Repo, UUID, NSWindow) {
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
            try seedShaping(project: repo.url.standardizedFileURL.path, pendingNotes: pendingNotes)
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


    private func seedShaping(project: String, pendingNotes: Int = 0) throws {
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
        // Unanchored, so the rail stacks them at its top rather than beside a line.
        tape.pendingNotes = (0..<pendingNotes).map { PlanNote(note: "Fixture note \($0): say more about the rollout and who signs it off.") }
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

    private static func everyDisplayAsleep() -> Bool {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return true }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &displays, &count) == .success else { return true }
        return displays.prefix(Int(count)).allSatisfy { CGDisplayIsAsleep($0) != 0 }
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

    private func all<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { all(type, in: $0) }
    }

    private func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let match = view as? T { return match }
        for sub in view.subviews { if let match = find(type, in: sub) { return match } }
        return nil
    }
}
