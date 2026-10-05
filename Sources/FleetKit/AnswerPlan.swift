import Foundation

/// Every keystroke needed to answer an `AskUserQuestion`, worked out before one is pressed.
///
/// **This is what makes driving the dialog deterministic rather than exploratory.** The
/// transcript already carries the questions and their options; the phone carries the reader's
/// choices. Between them the whole program is known in advance, so the driver executes a plan
/// and never reads the screen to decide what to do next.
///
/// **What the screen is still asked, and what it is no longer asked.** This file used to say "a
/// misread becomes a refusal instead of a wrong answer typed into a live terminal". That held
/// while the driver confirmed the cursor and the row's label before each press, and it stopped
/// holding when those checks were removed: they refused real dialogs whose only fault was an
/// option description wrapping onto a line beginning `0. `, and the screen the driver reads
/// carries no attributes to tell a dialog from prose that looks like one. Today the planned
/// drive asks one thing per step — is a select list on screen (`AgentDialogDriver.hasSelectList`)
/// — so a screen that disagrees with the plan is pressed on rather than refused, and the wrong
/// press is carried to the commit by the unconditional `.submit` step below.
///
/// Three kinds of refusal remain, and only the first two are about the plan's own steps:
///
/// - before any key moves: the phone's labels against this Mac's copy, and `plan` returning nil;
/// - **mid-drive, at every step**: a terminal that cannot be read at all, and a screen with no
///   select list on it. Those fire after keys have already gone out — the step-1 case is pinned
///   by `AnswerDiagnosticsTests.testAScreenThatGoesUnreadableAfterTheMoveStopsAtTheNextStep` —
///   and they stop the drive where it stands;
/// - the one-step `.allow`/`.option` drive, which is not a plan at all and still re-reads after
///   its move.
///
/// What is gone is the per-step agreement between the plan and what is drawn.
/// `SessionStore.drive(_:driver:injector:id:token:)` carries the full account.
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
            /// Land on question `question`'s "Type something" row and paste `text` into it.
            ///
            /// `thenPress` is whether Return follows, and it differs by shape — measured live
            /// against claude 2.1.289, `question-typed-*.captured.txt`:
            /// - **single-select**: the pasted text sits in the row and Return answers with it,
            ///   advancing exactly as an option's Return does. So it presses.
            /// - **multiSelect**: pasting into the row ticks its box by itself, and Return there
            ///   would toggle it back off. So it does not, and the cursor stays on the row for
            ///   the `.action` step that follows.
            case typed(question: Int, text: String, thenPress: Bool)
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

    /// One reader's choice within a question: one of its options, or words of their own on the
    /// "Type something" row (`AnswerSelection.text`).
    public enum Pick: Equatable, Sendable {
        case option(Int)
        case typed(String)
    }

    /// Whether `text` can be pasted into a "Type something" row as one answer.
    ///
    /// **No control characters, and that is a keystroke rule, not a style one.** The text goes
    /// in as a bracketed paste, and claude's field is one line: a newline is Return, which
    /// would commit the row part-way through the reader's words, and an Escape would end the
    /// paste and then cancel the whole dialog. Whitespace-only is refused because an empty row
    /// answers nothing — on a checkbox question it would not even tick.
    public static func acceptsTyped(_ text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespaces).isEmpty
            && !text.unicodeScalars.contains { $0.properties.generalCategory == .control }
    }

    /// Build the program, or `nil` when the answers do not fit the questions.
    ///
    /// Refuses rather than improvises. Every rejection here is a case where pressing keys
    /// would answer something other than what the reader chose:
    ///
    /// - a count mismatch — an answer per question, no more, no fewer;
    /// - an index outside a question's own options, which would land on "Type something." or
    ///   past the end of the list;
    /// - a single-select question given none or several answers;
    /// - a multiSelect question given none, which has no keystroke that means "nothing";
    /// - more than one typed answer to a question, or one `acceptsTyped` refuses.
    public static func plan(
        for questions: [PromptQuestion], answers: [[Int]]
    ) -> AnswerPlan? {
        plan(for: questions, picks: answers.map { $0.map(Pick.option) })
    }

    /// The same, where a pick may be the reader's own words.
    public static func plan(
        for questions: [PromptQuestion], picks: [[Pick]]
    ) -> AnswerPlan? {
        guard !questions.isEmpty, picks.count == questions.count else { return nil }
        var steps: [Step] = []

        for (index, question) in questions.enumerated() {
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
                  typed.allSatisfy(acceptsTyped)
            else { return nil }

            let isLast = index == questions.count - 1
            // "Type something" sits directly under the options, in no transcript.
            let typedRow = question.options.count

            guard question.multiSelect else {
                // One press, and the screen advances by itself.
                guard chosen.count + typed.count == 1 else { return nil }
                if let text = typed.first {
                    steps.append(.init(from: 0, to: typedRow, purpose: .typed(
                        question: index, text: text, thenPress: true)))
                } else {
                    steps.append(.init(from: 0, to: chosen[0],
                                       purpose: .option(question: index, option: chosen[0])))
                }
                continue
            }

            // Toggles. Enter does NOT advance here and the cursor stays where it landed, so
            // this is the one place a position carries from one step to the next. The typed
            // row comes last because it is the lowest row any pick can land on, which keeps
            // every arrow pointing down.
            var cursor = 0
            for option in chosen {
                steps.append(.init(from: cursor, to: option,
                                   purpose: .option(question: index, option: option)))
                cursor = option
            }
            if let text = typed.first {
                steps.append(.init(from: cursor, to: typedRow, purpose: .typed(
                    question: index, text: text, thenPress: false)))
                cursor = typedRow
            }
            steps.append(.init(from: cursor,
                               to: actionRow(optionCount: question.options.count),
                               purpose: .action(question: index, isLast: isLast)))
        }

        // **A lone single-select question has no review screen, so it gets no submit.** Its
        // one Return commits the answer — claude 2.1.289 draws no "Submit" tab for it and the
        // transcript closes on that press (measured live: a second Return landed in the
        // composer). A submit step there presses on whatever claude draws next, which in the
        // same probe was its own "Teach auto mode?" list, whose first row is Yes.
        if questions.count == 1, !questions[0].multiSelect {
            return AnswerPlan(steps: steps)
        }

        // The review screen, which every set and every checkbox question ends on. Its cursor is
        // already on "Submit answers", so this is a press with no movement — stated as a step
        // anyway, because the confirmation before it is the last chance to abort.
        steps.append(.init(from: 0, to: 0, purpose: .submit))
        return AnswerPlan(steps: steps)
    }
}
