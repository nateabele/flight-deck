import XCTest
@testable import FlightDeck

/// Records every injected event in one ordered transcript, because their *order* is the
/// contract: Return must arrive after the paste closes, and the yank after the Return —
/// see `SessionStore.rename`.
///
/// It also models the input bar, not just records against it. A kill that lands on a
/// draft clears the box; a kill that lands on an empty bar (or on one showing a
/// placeholder hint) changes nothing. That difference is the entire safety mechanism,
/// so a fake that ignored it would let the dangerous case pass.
@MainActor
final class SpyInjector: TextInjecting {
    enum Event: Equatable {
        case text(String)
        case ret
        case killLine
        case yank
        /// `+1` down, `-1` up. One case rather than two so a test can assert a run of movement
        /// as a list of numbers.
        case arrow(Int)
        case escape
    }

    var events: [Event] = []
    var sent: [String] { events.compactMap { if case .text(let t) = $0 { return t } else { return nil } } }

    /// What Claude Code actually holds in its input buffer.
    var buffer = ""
    /// What the screen shows. Independent of `buffer` on purpose: a hint renders text
    /// with an empty buffer behind it.
    var renderedRows: [String] = ["❯"]
    /// nil models a surface whose screen cannot be read at all.
    var viewportIsReadable = true

    /// The option list on screen, when one is up. Empty means the input bar is showing
    /// instead, which is what `renderedRows` models — and which every rename and typed-prompt
    /// test in this suite depends on.
    private(set) var options: [String] = []
    private(set) var selected = 0
    /// After this many arrows, record the event but stop moving the marker — a TUI that
    /// ignored a keystroke, repainted late, or was never the list we thought. `nil` moves for
    /// every arrow.
    var ignoreArrowsAfter: Int?
    private var arrowsSeen = 0
    /// Labels the list repaints into once it has been moved through — a dialog answered on the
    /// Mac and replaced by the next one while the driver was counting arrows. The marker still
    /// lands where it was sent; what it is sitting on is no longer what was asked for, which
    /// is the half of the interlock an index check alone cannot see.
    private var pendingRelabel: [String]?

    func sendText(_ text: String) { events.append(.text(text)) }
    func sendReturn() { events.append(.ret) }

    func sendKillLine() {
        events.append(.killLine)
        guard !buffer.isEmpty else { return }   // Ctrl+U on an empty line is a no-op
        buffer = ""
        renderedRows = ["❯"]
    }

    func sendYank() { events.append(.yank) }

    func sendArrowDown() { move(by: 1) }
    func sendArrowUp() { move(by: -1) }
    func sendEscape() { events.append(.escape) }

    private func move(by step: Int) {
        events.append(.arrow(step))
        arrowsSeen += 1
        guard !options.isEmpty, arrowsSeen <= (ignoreArrowsAfter ?? .max) else { return }
        selected = min(max(selected + step, 0), options.count - 1)
        if let next = pendingRelabel {
            options = next
            pendingRelabel = nil
        }
    }

    /// Puts a numbered option list on screen, in the shape claude draws and `ChoiceDialog`
    /// will read.
    func showOptions(_ labels: [String], selected: Int = 0) {
        options = labels
        self.selected = selected
    }

    /// Repaints the list with different labels the first time it is moved. See
    /// `pendingRelabel`.
    func relabelAfterArrows(_ labels: [String]) { pendingRelabel = labels }

    /// Whichever is up: the dialog if `showOptions` put one there, the input bar otherwise.
    ///
    /// The dialog rendering is copied off a real screen rather than invented — the marker at
    /// column 2, the number at column 4, the label at column 7, and the footer verbatim, as
    /// `Fixtures/Claude/permission-bash.captured.txt` has them. It is a permission prompt's
    /// layout specifically; an `AskUserQuestion` indents one column less, which is why the
    /// parser that reads both is tested against the captures and not against this.
    func readViewport() -> String? {
        guard viewportIsReadable else { return nil }
        let rule = String(repeating: "─", count: 92)
        guard options.isEmpty else {
            let rows = options.enumerated().map { index, label in
                " \(index == selected ? "❯" : " ") \(index + 1). \(label)"
            }
            return ([" Do you want to proceed?"] + rows
                    + ["", " Esc to cancel · Tab to amend · ctrl+e to explain"])
                .joined(separator: "\n")
        }
        return ([rule] + renderedRows + [rule, "  Opus 5 (1M context)  ⎇ master"])
            .joined(separator: "\n")
    }

    /// Puts a real draft in the bar: buffer and screen agree.
    func typeDraft(_ rows: [String]) {
        buffer = rows.joined(separator: "\n")
        renderedRows = ["❯\u{a0}" + rows[0]] + rows.dropFirst().map { "  " + $0 }
    }

    /// Puts a placeholder hint on screen with nothing behind it.
    func showHint(_ text: String) {
        buffer = ""
        renderedRows = ["❯\u{a0}" + text]
    }
}
