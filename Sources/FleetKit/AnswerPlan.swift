import Foundation

/// Every keystroke needed to answer an `AskUserQuestion`, worked out before one is pressed.
///
/// **This is what makes driving the dialog deterministic rather than exploratory.** The
/// transcript already carries the questions and their options; the phone carries the reader's
/// choices. Between them the whole program is known in advance, so the driver executes a plan
/// and checks each step against the screen — it never reads the screen to decide what to do
/// next. A misread becomes a refusal instead of a wrong answer typed into a live terminal.
///
/// The invariant it rests on: **every question's screen opens with the cursor on row 0.**
/// `ChoiceDialogTests.testEveryRealDialogOpensWithTheCursorOnItsFirstRow` asserts that over
/// every captured dialog, and `question-two-answered.captured.txt` shows it holding after an
/// auto-advance. Nothing here carries a cursor position across a screen boundary.
///
/// In `FleetKit` rather than beside the driver so the phone can build the same plan and show
/// what it is about to do — the `OpenPrompt` rule, for the reason `OpenPrompt` gives.
public struct AnswerPlan: Equatable, Sendable {
    /// One move-then-press.
    ///
    /// `from` and `to` are both stated rather than a delta, so a test reads as the screen
    /// positions it is about and the driver can confirm where it believes it started.
    public struct Step: Equatable, Sendable {
        /// What this step is for — carried so the driver knows which interlock to apply and
        /// what to say when one fails.
        public enum Purpose: Equatable, Sendable {
            /// Land on question `question`'s option `option` and press. On a single-select
            /// question that answers it and advances; on a multiSelect one it toggles a box
            /// and stays put.
            case option(question: Int, option: Int)
            /// The unnumbered row under a multiSelect question's options. It reads "Next"
            /// while questions remain and "Submit" when none do — see `actionLabel`.
            case action(question: Int, isLast: Bool)
            /// "Submit answers" on the review screen that follows the last question.
            case submit
        }

        public let from: Int
        public let to: Int
        public let purpose: Purpose

        public init(from: Int, to: Int, purpose: Purpose) {
            self.from = from
            self.to = to
            self.purpose = purpose
        }
    }

    public let steps: [Step]

    /// What a multiSelect question's unnumbered action row says.
    ///
    /// **"Submit" alone, "Next" inside a set**, captured in `question-checkbox.captured.txt`
    /// and `question-set-with-checkbox.captured.txt`. A driver that assumed one would press
    /// the other — expecting a commit and getting an advance, or the reverse — which is the
    /// single most consequential difference between the two shapes.
    public static func actionLabel(isLast: Bool) -> String { isLast ? "Submit" : "Next" }

    /// The row index of that action row, for a question with `optionCount` options.
    ///
    /// The rows are positional and stable: `0..<n` the options, `n` "Type something", `n + 1`
    /// the action row, `n + 2` "Chat about this". Verified rather than assumed —
    /// `question-checkbox-submit-focused.captured.txt` is Down×5 with four options landing on
    /// it. The two trailing rows are drawn by the TUI and appear in no transcript, which is
    /// why this is computed from the transcript's own count.
    public static func actionRow(optionCount: Int) -> Int { optionCount + 1 }

    /// The label of the review screen's first row, which the cursor already sits on.
    public static let submitAnswersLabel = "Submit answers"

    /// Build the program, or `nil` when the answers do not fit the questions.
    ///
    /// Refuses rather than improvises. Every rejection here is a case where pressing keys
    /// would answer something other than what the reader chose:
    ///
    /// - a count mismatch — an answer per question, no more, no fewer;
    /// - an index outside a question's own options, which would land on "Type something." or
    ///   past the end of the list;
    /// - a single-select question given none or several answers;
    /// - a multiSelect question given none, which has no keystroke that means "nothing".
    public static func plan(
        for questions: [PromptQuestion], answers: [[Int]]
    ) -> AnswerPlan? {
        guard !questions.isEmpty, answers.count == questions.count else { return nil }
        var steps: [Step] = []

        for (index, question) in questions.enumerated() {
            let chosen = answers[index].sorted()
            guard !chosen.isEmpty,
                  Set(chosen).count == chosen.count,
                  chosen.allSatisfy({ question.options.indices.contains($0) })
            else { return nil }

            let isLast = index == questions.count - 1

            guard question.multiSelect else {
                // One press, and the screen advances by itself.
                guard chosen.count == 1 else { return nil }
                steps.append(.init(from: 0, to: chosen[0],
                                   purpose: .option(question: index, option: chosen[0])))
                continue
            }

            // Toggles. Enter does NOT advance here and the cursor stays where it landed, so
            // this is the one place a position carries from one step to the next.
            var cursor = 0
            for option in chosen {
                steps.append(.init(from: cursor, to: option,
                                   purpose: .option(question: index, option: option)))
                cursor = option
            }
            steps.append(.init(from: cursor,
                               to: actionRow(optionCount: question.options.count),
                               purpose: .action(question: index, isLast: isLast)))
        }

        // The review screen, which every set and every single-select question ends on. Its
        // cursor is already on "Submit answers", so this is a press with no movement — stated
        // as a step anyway, because the confirmation before it is the last chance to abort.
        steps.append(.init(from: 0, to: 0, purpose: .submit))
        return AnswerPlan(steps: steps)
    }
}
