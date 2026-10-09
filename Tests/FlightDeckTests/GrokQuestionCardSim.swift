import FleetKit
@testable import FlightDeck

/// grok's question card as a state machine, drawn as plain text — the rules
/// `.superpowers/grok-tui-facts-2.md` §2 recorded live on grok 1.0.30, and nothing more:
///
/// - a digit on a single-select question selects and advances (submits on the last);
/// - a digit on a multi-select question CHECKS (never unchecks) and advances (submits on the last);
/// - Space toggles the focused checkbox and stays; `↑`/`↓` move the cursor, clamped;
/// - `z` opens the free-text editor (ticking `z` on a checkbox question); a paste goes into it;
///   Return there commits the text and advances (submits on the last);
/// - Return on a closed editor answers the focused row — what the drive must never rely on.
///
/// The cursor is NOT drawn, as grok draws it in colour only. `startFocus` lets a test put it
/// somewhere other than row 1 to prove the drive never assumes where it is.
@MainActor
final class GrokQuestionCardSim: TextInjecting {
    struct Question {
        let text: String
        let labels: [String]
        let multi: Bool
    }

    /// What grok would record, per question: chosen option indices and typed text.
    struct Answer: Equatable {
        var options: Set<Int> = []
        var typed: String?
    }

    enum Event: Equatable { case key(Character), up, down, paste(String), ret, control(Character), escape }

    let questions: [Question]
    private(set) var current = 0
    private(set) var answers: [Answer]
    private(set) var submitted = false
    private(set) var events: [Event] = []
    private var focus: Int
    private var editing = false
    private var buffer = ""
    /// The card's keyboard parked in the scrollback (Escape): keys go nowhere useful.
    var parked = false
    /// Drop the Nth Space press (1-based) without acting — a keystroke the TUI lost.
    var dropSpaceNumber: Int?
    private var spaces = 0

    init(_ questions: [Question], startFocus: Int = 0) {
        self.questions = questions
        answers = Array(repeating: Answer(), count: questions.count)
        focus = startFocus
    }

    private var question: Question { questions[current] }
    private var freeRow: Int { question.labels.count }

    // MARK: TextInjecting

    func sendText(_ text: String) {
        events.append(.paste(text))
        guard !submitted, !parked, editing else { return }
        buffer += text
    }

    func sendReturn() {
        events.append(.ret)
        guard !submitted, !parked else { return }
        if editing {
            answers[current].typed = buffer
            if !question.multi { answers[current].options = [] }
            editing = false
            advance()
        } else if focus < freeRow {
            if question.multi { answers[current].options.insert(focus) } else { answers[current].options = [focus] }
            advance()
        }
    }

    func sendCharacterKey(_ character: Character) {
        events.append(.key(character))
        guard !submitted, !parked else { return }
        if editing { buffer.append(character); return }
        if character == " " {
            spaces += 1
            if spaces == dropSpaceNumber { return }
            guard question.multi, focus < freeRow else { return }
            if answers[current].options.contains(focus) {
                answers[current].options.remove(focus)
            } else {
                answers[current].options.insert(focus)
            }
            return
        }
        if character == "z" {
            editing = true
            buffer = ""
            focus = freeRow
            return
        }
        guard let digit = character.wholeNumberValue, digit >= 1, digit <= question.labels.count else { return }
        let row = digit - 1
        focus = row
        if question.multi { answers[current].options.insert(row) } else { answers[current].options = [row] }
        advance()
    }

    func sendControlKey(_ letter: Character) { events.append(.control(letter)) }
    func clearEventsForTesting() { events.removeAll() }
    func sendArrowUp() {
        events.append(.up)
        guard !editing else { return }
        focus = max(0, focus - 1)
    }
    func sendArrowDown() {
        events.append(.down)
        guard !editing else { return }
        focus = min(freeRow, focus + 1)
    }
    func sendEscape() { events.append(.escape) }
    func sendKillLine() {}
    func sendYank() {}

    private func advance() {
        if current == questions.count - 1 {
            submitted = true
        } else {
            current += 1
            focus = 0
        }
    }

    // MARK: Screen

    func readViewport() -> String? {
        if submitted {
            return """
              main ~/proj   25K / 256K │ [Dashboard]

              ╭──────────────────────────────────────────────╮
              │ ❯                                            │
              ╰──────────────────────────── Grok 4.7 (high) ─╯

              Shift+Tab:mode  │  Ctrl+c:cancel  │  Ctrl+.:shortcuts
            """
        }
        var lines = ["  main ~/proj   25K / 256K │ [Dashboard]", "", "  ┃", "  ┃  \(question.text)", "  ┃", "  ┃"]
        let answer = answers[current]
        for (index, label) in question.labels.enumerated() {
            let mark: String
            if question.multi {
                mark = answer.options.contains(index) ? "[x]" : "[ ]"
            } else {
                mark = answer.options.contains(index) ? "(●)" : "(○)"
            }
            lines.append("  ┃  \(index + 1) \(mark) \(label)  about \(label)                         █")
        }
        let freeMark: String
        if question.multi {
            freeMark = (editing || answer.typed != nil) ? "[x]" : "[ ]"
        } else {
            freeMark = (editing || answer.typed != nil) ? "(●)" : "(○)"
        }
        if editing {
            lines.append("  ┃  z \(freeMark) ❯ \(buffer)".trimmingTrailingSpaces())
        } else {
            lines.append("  ┃  z \(freeMark) Type your answer here")
        }
        lines.append("  ┃")
        let position = questions.count > 1 ? "[\(current + 1)/\(questions.count)] ↑/↓ navigate · ←/→ question · y copy"
                                           : "↑/↓ navigate · y copy"
        let action = editing ? "Enter:edit" : (current == questions.count - 1 ? "Enter:submit" : "Enter:select")
        lines.append("  ┃  \(position)                    \(action)")
        lines.append("  ┃")
        lines.append("")
        if parked {
            lines.append("  Tab/Space:question  │  →:expand  │  Ctrl+c:cancel  │  Ctrl+.:shortcuts")
        } else if editing {
            lines.append("  Enter:submit  │  Esc:back")
        } else {
            lines.append("  Tab:next answer  │  Esc:scrollback  │  Shift+x:dismiss")
        }
        return lines.joined(separator: "\n")
    }
}

private extension String {
    func trimmingTrailingSpaces() -> String {
        var s = self
        while s.hasSuffix(" ") { s.removeLast() }
        return s
    }
}
