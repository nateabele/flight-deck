import AppKit
import IntakeKit
import SwiftUI
import XCTest
@testable import FlightDeck

/// Where the human was reading the plan, through the real window shape — `RootView`,
/// `ProjectView`, a shaping `IntakeDetailView` with its plan editor — in an offscreen titled
/// window, as `ProjectViewIntakeListLiveTests` hosts it.
///
/// Selecting an agent's tab, or another project, replaces `ProjectView`; the plan editor and the
/// document's scroll view are made again at the top. The reading position is kept per intake
/// (`IntakeService.planScroll`) as a line of text, and put back once the plan is laid out that
/// far (`PlanTextView.Coordinator.beginReadingRestore`).
@MainActor
final class ProjectViewPlanScrollLiveTests: XCTestCase {
    private var root: URL!
    private var window: NSWindow?
    private var restoreDefaults: (() -> Void)?

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ProjectViewPlanScrollLiveTests-\(UUID())")
    }

    override func tearDown() {
        restoreDefaults?()
        window?.orderOut(nil)
        window?.contentViewController = nil
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    /// Two projects with a shaping intake each, A showing, and an agent's tab to switch to.
    private struct World {
        let store: SessionStore
        let prefs: PreferencesStore
        let service: IntakeService
        let a: Repo
        let b: Repo
        let session: UUID
        let window: NSWindow
        let intake: UUID
    }

    private func world(width: CGFloat = 1300, composerDraft: String? = nil) throws -> World {
        let prefs = PreferencesStore(persistence: PreferencesStoreTests.MemoryPersistence())
        let store = SessionStore(provider: nil, persistence: SessionPersistenceTests.FakePersistence(),
                                 preferences: prefs, intakesRoot: root)
        let tag = UUID().uuidString
        store.newSession(in: URL(fileURLWithPath: "/w/scroll-a-\(tag)", isDirectory: true))
        store.newSession(in: URL(fileURLWithPath: "/w/scroll-b-\(tag)", isDirectory: true))
        let a = try XCTUnwrap(store.repos.first { $0.url.path.hasSuffix("scroll-a-\(tag)") })
        let b = try XCTUnwrap(store.repos.first { $0.url.path.hasSuffix("scroll-b-\(tag)") })
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
            for repo in [a, b] { service.select(nil, inProject: repo.url.path) }
        }
        for repo in [a, b] {
            let path = repo.url.standardizedFileURL.path
            service.select(service.intakes(forProject: path).first?.id, inProject: path)
        }
        if let composerDraft {
            let project = a.url.standardizedFileURL.path
            service.setDraft(composerDraft, inProject: project)
            service.setComposerExpanded(true, inProject: project)
            let reset = restoreDefaults
            restoreDefaults = {
                reset?()
                service.setDraft("", inProject: project)
                service.setComposerExpanded(false, inProject: project)
            }
        }
        store.selectProject(a.id)
        let window = host(RootView(store: store, preferences: prefs), width: width)
        let intake = try XCTUnwrap(service.intakes(forProject: a.url.standardizedFileURL.path).first?.id)
        return World(store: store, prefs: prefs, service: service, a: a, b: b, session: session, window: window, intake: intake)
    }

    private func editor(in window: NSWindow) -> PlanNSTextView? {
        window.contentView.flatMap { find(PlanNSTextView.self, in: $0, where: { $0.accessibilityIdentifier() == "plan-editor" }) }
    }

    /// The plan editor once it is laid out and its position restored; a different one from
    /// `old`, when the view is expected to have been replaced.
    private func readyEditor(in window: NSWindow, replacing old: PlanNSTextView? = nil, timeout: TimeInterval = 20) throws -> PlanNSTextView {
        let until = Date().addingTimeInterval(timeout)
        var found: PlanNSTextView?
        while Date() < until {
            settle(0.05)
            found = editor(in: window)
            if let found, found !== old, let live = found.delegate as? PlanTextView.Coordinator, !found.layingOutWholePlan,
               live.scrolling.target == nil { break }
        }
        let view = try XCTUnwrap(found, "no plan editor")
        settle(0.2)
        return view
    }

    private func coordinator(_ editor: PlanNSTextView) -> PlanTextView.Coordinator {
        editor.delegate as! PlanTextView.Coordinator
    }

    private func clip(_ editor: PlanNSTextView) throws -> NSClipView {
        try XCTUnwrap(editor.enclosingScrollView?.contentView)
    }

    /// Scrolls the document so the plan's `fraction` is under the reading line, and lets the
    /// position be saved.
    private func scrollPlan(_ editor: PlanNSTextView, toFraction fraction: CGFloat) throws -> PlanReadingAnchor {
        let clip = try clip(editor)
        let scroll = try XCTUnwrap(editor.enclosingScrollView)
        let document = try XCTUnwrap(scroll.documentView)
        let y = editor.convert(NSPoint(x: 0, y: editor.frame.height * fraction), to: document).y
        clip.scroll(to: NSPoint(x: 0, y: min(y, document.frame.height - clip.bounds.height)))
        scroll.reflectScrolledClipView(clip)
        settle(PlanTextView.Coordinator.readingQuiet + 0.4)
        return try XCTUnwrap(coordinator(editor).readingAnchor())
    }

    private func awayAndBack(_ w: World) {
        w.store.selectSession(w.session)
        settle()
        w.store.selectProject(w.a.id)
    }

    func testTheReadingPositionSurvivesAnAgentsTab() throws {
        let w = try world()
        settle(1.5)
        let first = try readyEditor(in: w.window)
        let before = try scrollPlan(first, toFraction: 0.5)
        let scrolledTo = try clip(first).bounds.minY
        XCTAssertGreaterThan(before.offset, 1_000)
        XCTAssertEqual(w.service.planScroll(w.intake).anchor?.offset, before.offset, "saved on the quiet scroll")

        w.store.selectSession(w.session)
        settle()
        XCTAssertNil(editor(in: w.window), "an agent's tab replaces the project view")

        // From the moment the project is shown again, at every turn: the page is hidden or already
        // at the line — it never shows the top of the document.
        w.store.selectProject(w.a.id)
        var shown: [CGFloat] = []
        var hidden = 0
        var seen = 0
        let until = Date().addingTimeInterval(3)
        while Date() < until {
            RunLoop.current.run(until: Date().addingTimeInterval(0.004))
            guard let editor = editor(in: w.window), let scroll = editor.enclosingScrollView else { continue }
            seen += 1
            if scroll.alphaValue > 0.5 { shown.append(scroll.contentView.bounds.minY) } else { hidden += 1 }
        }
        XCTAssertGreaterThan(seen, 10)
        let editor = try readyEditor(in: w.window)
        let after = try XCTUnwrap(coordinator(editor).readingAnchor())
        XCTAssertEqual(after.offset, before.offset, "the same line is under the reading line")
        XCTAssertEqual(after.within, before.within, accuracy: 22)
        XCTAssertEqual(try clip(editor).bounds.minY, scrolledTo, accuracy: 22)
        let wrong = shown.filter { abs($0 - scrolledTo) > 22 }
        XCTAssertTrue(wrong.isEmpty, "frames shown at the wrong place (\(wrong.count) of \(shown.count), \(hidden) hidden): \(Set(wrong).sorted().prefix(6))")
        XCTAssertLessThanOrEqual(coordinator(editor).scrolling.applications, 3, "the page was moved to the line, not hunted for it")
        print("PlanScroll restore: \(seen) turns with the editor, \(hidden) hidden, \(shown.count) shown, \(coordinator(editor).scrolling.applications) moves")
    }

    func testTheReadingPositionSurvivesAnotherProjectAndBack() throws {
        let w = try world()
        settle(1.5)
        let first = try readyEditor(in: w.window)
        let before = try scrollPlan(first, toFraction: 0.6)

        w.store.selectProject(w.b.id)
        let bEditor = try readyEditor(in: w.window, replacing: first)
        XCTAssertEqual(try XCTUnwrap(coordinator(bEditor).readingAnchor()).offset, 0, "B's plan has its own position: the top")
        w.store.selectProject(w.a.id)
        let editor = try readyEditor(in: w.window, replacing: bEditor)
        let after = try XCTUnwrap(coordinator(editor).readingAnchor())
        XCTAssertEqual(after.offset, before.offset)
        XCTAssertEqual(after.within, before.within, accuracy: 22)
    }

    func testTheSameLineAtANewWidth() throws {
        let w = try world(width: 1300)
        settle(1.5)
        let first = try readyEditor(in: w.window)
        let before = try scrollPlan(first, toFraction: 0.5)
        let scrolledTo = try clip(first).bounds.minY

        w.store.selectSession(w.session)
        settle()
        w.window.setFrame(NSRect(x: -10_000, y: -10_000, width: 1000, height: 800), display: true)
        settle()
        w.store.selectProject(w.a.id)
        let editor = try readyEditor(in: w.window)
        let after = try XCTUnwrap(coordinator(editor).readingAnchor())
        XCTAssertEqual(after.offset - after.into, before.offset - before.into, "the same paragraph")
        XCTAssertEqual(after.within, before.within, accuracy: 22)
        XCTAssertGreaterThan(abs(try clip(editor).bounds.minY - scrolledTo), 200, "at the new width the pixels are elsewhere")
    }

    func testTheSameLineWithASectionFoldedAboveIt() throws {
        let w = try world()
        settle(1.5)
        let first = try readyEditor(in: w.window)
        let before = try scrollPlan(first, toFraction: 0.5)
        let scrolledTo = try clip(first).bounds.minY

        w.store.selectSession(w.session)
        settle()
        let folds = w.service.planFolds(w.intake)
        for i in 0..<10 { folds.folds.set(PlanFoldKey(text: "## \(i). Section \(i)", occurrence: 0), folded: true) }
        w.store.selectProject(w.a.id)
        let editor = try readyEditor(in: w.window)
        let after = try XCTUnwrap(coordinator(editor).readingAnchor())
        XCTAssertEqual(after.offset, before.offset)
        XCTAssertEqual(after.within, before.within, accuracy: 22)
        XCTAssertGreaterThan(abs(try clip(editor).bounds.minY - scrolledTo), 100, "the folds moved the line; the page followed it")
    }

    /// The caret and selection were lost with the editor too: a new text view starts with the
    /// caret at the top and the keyboard elsewhere.
    func testTheCaretAndTheKeyboardSurviveAnAgentsTab() throws {
        let w = try world()
        settle(1.5)
        let first = try readyEditor(in: w.window)
        let scrolled = try scrollPlan(first, toFraction: 0.4)
        XCTAssertTrue(w.window.makeFirstResponder(first))
        let selection = NSRange(location: scrolled.offset + 300, length: 6)
        first.setSelectedRange(selection)
        // Revealing the selection may have moved the page: the position is the one it ended at.
        settle(PlanTextView.Coordinator.readingQuiet + 0.4)
        let before = try XCTUnwrap(coordinator(first).readingAnchor())

        awayAndBack(w)
        let editor = try readyEditor(in: w.window)
        XCTAssertTrue(w.window.firstResponder === editor, "the editor had the keyboard")
        XCTAssertEqual(editor.selectedRange(), selection)
        XCTAssertEqual(try XCTUnwrap(coordinator(editor).readingAnchor()).offset, before.offset)
    }

    /// The expanded composer is a long document in a scroll view of its own, and is made again
    /// the same way; its draft was already kept, its place in it was not.
    func testTheExpandedComposerKeepsItsPlaceInTheDraft() throws {
        let w = try world(composerDraft: PlanReadingMemoryTests.plan(0..<150))
        settle(1.5)
        let id = "intake-intent-expanded-field"
        let find = { () -> PlanNSTextView? in
            guard let content = self.window?.contentView else { return nil }
            return self.find(PlanNSTextView.self, in: content, where: { $0.accessibilityIdentifier() == id })
        }
        let first = try XCTUnwrap(find())
        let ready = { (editor: PlanNSTextView) in
            let until = Date().addingTimeInterval(20)
            while Date() < until, editor.layingOutWholePlan || (editor.delegate as? PlanTextView.Coordinator)?.scrolling.target != nil {
                self.settle(0.05)
            }
            self.settle(0.3)
        }
        ready(first)
        let before = try scrollPlan(first, toFraction: 0.5)
        XCTAssertGreaterThan(before.offset, 1_000)

        w.store.selectSession(w.session)
        settle()
        w.store.selectProject(w.a.id)
        settle(1)
        let editor = try XCTUnwrap(find())
        XCTAssertFalse(editor === first)
        ready(editor)
        let after = try XCTUnwrap(coordinator(editor).readingAnchor())
        XCTAssertEqual(after.offset, before.offset)
        XCTAssertEqual(after.within, before.within, accuracy: 22)
    }

    // MARK: - Fixtures

    private func seedShaping(project: String) throws {
        var intake = Intake(projectPath: project, intent: "Plan the thing")
        intake.state = .shaping
        intake.recommended = .featurePlan
        intake.chosenPreset = .featurePlan
        intake.roundConfig = PresetExpansion.config(for: .featurePlan, available: .defaults)
        try IntakeStore(root: root).save(intake)
        let tapes = TapeStore(intakeDirectory: IntakeStore(root: root).directory(for: intake.id))
        var tape = tapes.loadTape()
        let plan = PlanReadingMemoryTests.plan(0..<150)
        try tapes.writeCheckpoint(Checkpoint(id: 1, stage: .draft, round: 0, major: true, createdAt: Date()),
                                  files: ["drafts/0.md": Data("# Plan\n\n\(plan)\n".utf8)], into: &tape)
        tape.status = .paused
        try tapes.saveTape(tape)
    }

    private func host(_ view: some View, width: CGFloat) -> NSWindow {
        let frame = NSRect(x: -10_000, y: -10_000, width: width, height: 800)
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

    private func find<T: NSView>(_ type: T.Type, in view: NSView, where matches: (T) -> Bool = { _ in true }) -> T? {
        if let match = view as? T, matches(match) { return match }
        for sub in view.subviews { if let match = find(type, in: sub, where: matches) { return match } }
        return nil
    }
}
