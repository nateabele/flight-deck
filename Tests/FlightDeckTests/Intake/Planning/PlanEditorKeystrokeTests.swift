import AppKit
import IntakeKit
import XCTest
@testable import FlightDeck

/// The cost of one keystroke in the whole plan editor — styler, edit layer, both decoration
/// layers, the notes' bands and the churn lane — on the plan size the budgets are set for.
/// Measured through `insertText` in a window, the way typing arrives, not one layer at a time:
/// each layer was within budget alone, and together they were not.
final class PlanEditorKeystrokeTests: XCTestCase {
    static let hot = "## 4. Dispatch rules"

    /// 2,000 lines: 250 sections of eight, §4 the one the cycle keeps changing.
    static func plan() -> String {
        var lines: [String] = []
        for i in 0..<250 {
            lines += [i == 4 ? hot : "## \(i). Section \(i)", "",
                      "Prose number \(i) with **bold** and `code`. Techs check in on arrival \(i).",
                      "- item one of \(i)", "1. item two of \(i)", "```", "let x = \(i)", "```"]
        }
        return lines.joined(separator: "\n")
    }

    static func cycle() -> ConvergenceCycle {
        let codex = ModelChoice(harness: .codex, model: "gpt-6-sol", effort: "high")
        func point(_ round: Int, _ changes: Int, _ agree: Double, _ churn: [String: Int]) -> ConvergencePoint {
            ConvergencePoint(checkpoint: round + 2, stage: .refine, round: round, changeCount: changes,
                             linesChurned: churn.values.reduce(0, +), agreeRatio: agree, sectionChurn: churn, reviewerModel: codex)
        }
        return ConvergenceSeries.assess(.refine, [point(1, 36, 0.76, [hot: 10, "## 2. Section 2": 20]),
                                                   point(2, 15, 0.8, [hot: 6, "## 2. Section 2": 6]),
                                                   point(3, 22, 0.57, [hot: 14, "## 3. Section 3": 8]),
                                                   point(4, 29, 0.48, [hot: 22, "## 3. Section 3": 6, "## 200. Section 200": 2])])
    }

    /// A full editor in a window: edit layer over a lightly edited plan, ten notes, and the
    /// churn lane with §4 hot and its sentence flipping (and one quiet marker far below the fold).
    @MainActor
    static func editor() -> (PlanTextView.Coordinator, PlanEditorContainer, PlanNotesController, NSWindow) {
        let generated = plan()
        var lines = generated.components(separatedBy: "\n")
        lines[402] = "Prose number 50 with a human's change."
        lines.insert("- a new item", at: 1203)
        let edited = lines.joined(separator: "\n")

        let notes = PlanNotesController()
        notes.checkpoint = 1
        for i in 0..<10 {
            let quote = "Techs check in on arrival \(i * 20)."
            let anchor = NoteAnchor(checkpoint: 1, selecting: edited.range(of: quote)!, in: edited)
            notes.tapeNotes.append(TapeNote(note: PlanNote(kind: .comment, note: "n\(i)", anchor: anchor), consumedBy: nil))
        }
        let versions = [SectionVersion(round: "R2", text: "Prose number 4 with bold and code.", verdict: .agree),
                        SectionVersion(round: "R3", text: "Prose number 4 with bold and code again.", verdict: .somewhat)]
        let churn = ChurnLaneInput(cycle: cycle(), versions: { $0 == hot ? versions : [] }, onOpen: { _ in })
        let view = PlanTextView(text: .constant(edited), editable: true, onCommit: { _ in }, incoming: nil, onShowIncoming: {})
            .editLayer(generated: generated)
            .churnLane(churn)
            .annotating(notes)
        let coordinator = view.makeCoordinator()
        let container = PlanEditorContainer(onShow: {})
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = container
        coordinator.textView = container.textView
        coordinator.revertButton = container.revert
        container.textView.delegate = coordinator
        container.textView.textStorage?.delegate = coordinator
        coordinator.load(edited)
        coordinator.notesBridge.attach(notes, to: container.textView)
        container.churnLane.update(churn)
        coordinator.churnChanged()
        container.layoutSubtreeIfNeeded()
        window.makeFirstResponder(container.textView)
        container.textView.displayIfNeeded()
        return (coordinator, container, notes, window)
    }

    /// Budget: under 8 ms a keystroke in Debug (W4 review), typed into the middle of a body line
    /// of a 2,000-line plan with every layer on.
    @MainActor
    func testKeystrokeWithEveryLayerIsUnderBudget() {
        let (coordinator, container, _, window) = Self.editor()
        defer { coordinator.timer?.invalidate(); window.close() }
        let view = container.textView
        let at = (view.string as NSString).range(of: "Techs check in on arrival 130.").location
        view.setSelectedRange(NSRange(location: at, length: 0))
        // Warm-up: first-use costs (font caches, the lane's first layout) are not a keystroke's.
        view.insertText("w", replacementRange: view.selectedRange())

        let clock = ContinuousClock()
        let keys = 40
        var total = Duration.zero
        for i in 0..<keys {
            let key = String(UnicodeScalar(UInt8(97 + i % 26)))
            total += clock.measure {
                view.insertText(key, replacementRange: view.selectedRange())
                view.displayIfNeeded()
            }
        }
        let each = total / keys
        print("PlanEditor keystroke timing: \(each) per keystroke over \(keys) (2000 lines, 10 notes, hot §4)")
        XCTAssertLessThan(each, .milliseconds(8))
    }
}
