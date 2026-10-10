import FleetKit
import Foundation

/// How a whole `ask_user_question` answer is keyed into grok's question card, and how each step
/// is checked against the screen before its keys go out.
///
/// Every rule here was probed live on grok 1.0.30 (`.superpowers/grok-tui-facts-2.md` §0–§2):
///
/// - **A digit COMMITS.** On a single-select question it selects and advances to the next
///   question, or submits the whole set on the last one. On a multi-select question it CHECKS
///   that row (never unchecks) and advances or submits too. There is no review screen.
/// - **Space toggles the focused checkbox and stays.** The cursor is drawn in colour only, so a
///   plain-text read cannot see it; `↑`/`↓` move it and clamp at the ends, so enough `↑` puts it
///   on row 1 from anywhere. The checkboxes themselves ARE in plain text (`[ ]`/`[x]`), which is
///   what every toggle is confirmed against before the next key.
/// - **A typed answer is `z`, a paste, then Return** — the one Return this drive ever sends,
///   and only into an open editor, where it commits the text and advances (or submits).
///
/// So a question is driven as: toggle every checkbox but the last pick with Space (multi only),
/// then commit with the last pick's own key, or with the typed text. Return never lands on an
/// option row; grok focuses rows a person did not choose (part 1, §0.5), and a Return there is
/// an answer nobody gave.
enum GrokAnswerPlan {
    /// The steps for `picks`, or nil for a shape that cannot be keyed: the same refusals as
    /// `AnswerPlan.plan` (a count mismatch, an empty or duplicate pick, an index out of range,
    /// more than one typed answer, text `AnswerPlan.acceptsTyped` refuses, several picks on a
    /// single-select question), plus a question the phone already marked unanswerable.
    static func plan(for questions: [PromptQuestion], picks: [[AnswerPlan.Pick]]) -> [KeyedAnswerStep]? {
        guard !questions.isEmpty, picks.count == questions.count else { return nil }
        var steps: [KeyedAnswerStep] = []
        for (index, question) in questions.enumerated() {
            guard question.isAnswerable else { return nil }
            var chosen: [Int] = []
            var typed: [String] = []
            for pick in picks[index] {
                switch pick {
                case .option(let option): chosen.append(option)
                case .typed(let text): typed.append(text)
                }
            }
            chosen.sort()
            guard !chosen.isEmpty || !typed.isEmpty,
                  Set(chosen).count == chosen.count,
                  chosen.allSatisfy({ question.options.indices.contains($0) }),
                  typed.count <= 1,
                  typed.allSatisfy(AnswerPlan.acceptsTyped)
            else { return nil }

            func step(_ checked: Set<Int>?, _ editor: String?, _ keys: [KeyedAnswerStep.Key]) -> KeyedAnswerStep {
                KeyedAnswerStep(expect: .init(question: index, checked: checked, editor: editor), keys: keys)
            }
            func typedSteps(_ text: String, checked: Set<Int>?) -> [KeyedAnswerStep] {
                [step(checked, nil, [.freeText]),
                 step(checked, "", [.paste(text)]),
                 step(checked, text, [.commitText])]
            }

            guard question.multiSelect else {
                guard chosen.count + typed.count == 1 else { return nil }
                if let text = typed.first {
                    steps += typedSteps(text, checked: nil)
                } else {
                    steps.append(step(nil, nil, [.option(chosen[0])]))
                }
                continue
            }

            // The commit is the typed text when there is one, else the last pick's own key;
            // everything before it is a Space toggle.
            let toggles = typed.isEmpty ? Array(chosen.dropLast()) : chosen
            var checked: Set<Int> = []
            if !toggles.isEmpty {
                // Rows plus the free-text row: enough `↑` to reach row 1 from any of them.
                steps.append(step(checked, nil, Array(repeating: .up, count: question.options.count + 1)))
            }
            var cursor = 0
            for option in toggles {
                steps.append(step(checked, nil, Array(repeating: .down, count: option - cursor) + [.toggle]))
                checked.insert(option)
                cursor = option
            }
            if let text = typed.first {
                steps += typedSteps(text, checked: checked)
            } else {
                steps.append(step(checked, nil, [.option(chosen[chosen.count - 1])]))
            }
        }
        return steps
    }

    /// The keys for `step`, or nil unless the screen shows exactly the state the step expects:
    /// the card has the keyboard, it is on the right question of the right set, its rows read the
    /// transcript's labels in order, and its checkboxes and editor are as the drive left them.
    static func keystrokes(
        for step: KeyedAnswerStep, questions: [PromptQuestion], inViewport viewport: String
    ) -> [KeyedKeystroke]? {
        let expect = step.expect
        guard questions.indices.contains(expect.question),
              let card = GrokScreen.questionCard(inViewport: viewport)
        else { return nil }
        let question = questions[expect.question]

        // Which question. A set prints `[i/n]`; a lone question prints none.
        if questions.count > 1 {
            guard card.position == .init(index: expect.question + 1, count: questions.count) else { return nil }
        } else {
            guard card.position == nil else { return nil }
        }
        guard let title = card.title, titleMatches(title, question: question.question) else { return nil }
        guard card.options.count == question.options.count,
              zip(card.options, question.options).allSatisfy({ GrokScreen.row($0, reads: $1.label) }),
              card.options.allSatisfy({ ($0.checked != nil) == question.multiSelect })
        else { return nil }

        if let wanted = expect.checked {
            let shown = Set(card.options.indices.filter { card.options[$0].checked == true })
            guard shown == wanted else { return nil }
        }
        if let text = expect.editor {
            // The editor shows the start of what was pasted; a long answer wraps below it.
            guard let shown = card.editorText,
                  text.isEmpty ? shown.isEmpty : (!shown.isEmpty && text.hasPrefix(shown))
            else { return nil }
        } else {
            // A closed editor on an untouched free-text row, with the card holding the keyboard —
            // parked in the scrollback, a digit would go to the scrollback instead.
            guard card.editorText == nil, card.hasKeyboard,
                  card.freeText.checked != true, !card.freeText.focused
            else { return nil }
        }

        var out: [KeyedKeystroke] = []
        for key in step.keys {
            switch key {
            case .option(let index):
                guard card.options.indices.contains(index) else { return nil }
                out.append(.character(card.options[index].key))
            case .freeText: out.append(.character(card.freeText.key))
            case .toggle: out.append(.character(" "))
            case .up: out.append(.arrowUp)
            case .down: out.append(.arrowDown)
            case .paste(let text): out.append(.paste(text))
            case .commitText: out.append(.returnKey)
            }
        }
        return out
    }

    /// The card's first text line against the transcript's question: equal, or its start when the
    /// question wraps or is cut short with `…`. Whitespace is compared collapsed.
    static func titleMatches(_ title: String, question: String) -> Bool {
        var shown = collapse(title)
        if shown.hasSuffix("…") { shown = collapse(String(shown.dropLast())) }
        guard !shown.isEmpty else { return false }
        return collapse(question).hasPrefix(shown)
    }

    private static func collapse(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
