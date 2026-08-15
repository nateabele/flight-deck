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

    func sendText(_ text: String) { events.append(.text(text)) }
    func sendReturn() { events.append(.ret) }

    func sendKillLine() {
        events.append(.killLine)
        guard !buffer.isEmpty else { return }   // Ctrl+U on an empty line is a no-op
        buffer = ""
        renderedRows = ["❯"]
    }

    func sendYank() { events.append(.yank) }

    func readViewport() -> String? {
        guard viewportIsReadable else { return nil }
        let rule = String(repeating: "─", count: 92)
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
