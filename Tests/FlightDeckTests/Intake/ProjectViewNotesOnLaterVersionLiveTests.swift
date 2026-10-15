import AppKit
import IntakeKit
import SwiftUI
import XCTest
@testable import FlightDeck

/// Writing a note on the plan after synthesis, through the real window shape (`RootView`,
/// `ProjectView`, a shaping `IntakeDetailView`) in an offscreen titled window: select text in the
/// plan, press a kind on the selection toolbar's panel with a real mouse event, and a draft card
/// opens in the notes rail. The intake has notes the synthesis round already read, written on
/// the drafts, as the maintainer's LarkOS intake does.
@MainActor
final class ProjectViewNotesOnLaterVersionLiveTests: XCTestCase {
    private var root: URL!
    private var window: NSWindow?
    private var restoreDefaults: (() -> Void)?

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ProjectViewNotesOnLaterVersionLiveTests-\(UUID())")
    }

    override func tearDown() {
        restoreDefaults?()
        window?.orderOut(nil)
        window?.contentViewController = nil
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private func world(synthesized: Bool = true) throws -> NSWindow {
        let prefs = PreferencesStore(persistence: PreferencesStoreTests.MemoryPersistence())
        let store = SessionStore(provider: nil, persistence: SessionPersistenceTests.FakePersistence(),
                                 preferences: prefs, intakesRoot: root)
        let tag = UUID().uuidString
        store.newSession(in: URL(fileURLWithPath: "/w/notes-later-\(tag)", isDirectory: true))
        let repo = try XCTUnwrap(store.repos.first { $0.url.path.hasSuffix("notes-later-\(tag)") })
        var settings = prefs.projectSettings(repo.url.path)
        settings.flywheelEnabled = true
        prefs.setProjectSettings(repo.url.path, settings)
        try seedShaping(project: repo.url.standardizedFileURL.path, synthesized: synthesized)
        let service = store.intakeService
        service.pollTapes()
        restoreDefaults = { service.select(nil, inProject: repo.url.path) }
        service.select(service.intakes(forProject: repo.url.standardizedFileURL.path).first?.id, inProject: repo.url.standardizedFileURL.path)
        store.selectProject(repo.id)
        return host(RootView(store: store, preferences: prefs), width: 1300)
    }

    private func seedShaping(project: String, synthesized: Bool) throws {
        var intake = Intake(projectPath: project, intent: "Plan the thing")
        intake.state = .shaping
        intake.recommended = .featurePlan
        intake.chosenPreset = .featurePlan
        intake.roundConfig = PresetExpansion.config(for: .featurePlan, available: .defaults)
        try IntakeStore(root: root).save(intake)
        let tapes = TapeStore(intakeDirectory: IntakeStore(root: root).directory(for: intake.id))
        var tape = tapes.loadTape()
        let table = "| Decision | Choice |\n| --- | --- |\n| Tenant membership alone never | grants access to an app |\n| Each owner controls | a specific invite list |\n"
        let drafts = "# Plan\n\n\(PlanReadingMemoryTests.plan(0..<20))\n\n\(table)\n"
        let synthesis = drafts.replacingOccurrences(of: "Techs check in on", with: "Crews report on")
        try tapes.writeCheckpoint(Checkpoint(id: 1, stage: .draft, round: 0, major: true, createdAt: Date()),
                                  files: ["drafts/0.md": Data(drafts.utf8)], into: &tape)
        guard synthesized else { tape.status = .paused; try tapes.saveTape(tape); return }
        var record = RoundRecord()
        record.annotations = ["Techs check in on arrival 3.", "Techs check in on arrival 7."].map { q in
            PlanNote(kind: .question, note: "why", anchor: NoteAnchor(checkpoint: 1, selecting: drafts.range(of: q)!, in: drafts))
        }
        try tapes.writeCheckpoint(Checkpoint(id: 2, parent: 1, stage: .synthesis, round: 0, major: true, createdAt: Date(), record: record),
                                  files: ["plan.md": Data(synthesis.utf8)], into: &tape)
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

    private func settle(_ seconds: TimeInterval = 0.6) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }

    private func find<T: NSView>(_ type: T.Type, in view: NSView, where matches: (T) -> Bool = { _ in true }) -> T? {
        if let match = view as? T, matches(match) { return match }
        for sub in view.subviews { if let match = find(type, in: sub, where: matches) { return match } }
        return nil
    }

    private func pressComment(synthesized: Bool, selecting phrase: String? = nil) throws -> Bool {
        let window = try world(synthesized: synthesized)
        settle(2)
        let content = try XCTUnwrap(window.contentView)
        let editor = try XCTUnwrap(find(PlanNSTextView.self, in: content, where: { $0.accessibilityIdentifier() == "plan-editor" }))
        let word = synthesized ? "Crews report" : "Techs check in"
        XCTAssertTrue(editor.string.contains("\(word) on arrival 3."))
        XCTAssertTrue(window.makeFirstResponder(editor))
        let text = editor.string
        editor.setSelectedRange(NSRange(try XCTUnwrap(text.range(of: phrase ?? "\(word) on arrival 11.")), in: text))
        settle(0.8)
        let panel = try XCTUnwrap(window.childWindows?.first { $0 is NSPanel }, "the selection toolbar did not open")
        let point = NSPoint(x: 34 + 3 + 30, y: panel.frame.height / 2)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                         windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            panel.sendEvent(event)
        }
        settle(1)
        let notes = (editor.delegate as? PlanTextView.Coordinator)?.notesBridge.boundNotes
        return notes?.draft != nil
    }

    func testPressingAKindOnTheToolbarOpensADraftOnTheFirstVersion() throws {
        XCTAssertTrue(try pressComment(synthesized: false), "the control: the first version")
    }

    /// The plans the maintainer writes notes on hold tables, which the editor draws as grids.
    func testPressingAKindOnTheToolbarOpensADraftOnTextInATableAfterSynthesis() throws {
        XCTAssertTrue(try pressComment(synthesized: true, selecting: "a specific invite list"), "a selection inside a table cell")
    }

    func testPressingAKindOnTheToolbarOpensADraftAfterSynthesis() throws {
        XCTAssertTrue(try pressComment(synthesized: true), "pressing Comment after synthesis opened no draft in the rail")
    }
}
