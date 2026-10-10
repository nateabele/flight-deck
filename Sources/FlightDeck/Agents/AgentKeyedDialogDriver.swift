import FleetKit
import Foundation

/// **A dialog answered by one keypress that names the row — never by Return.**
///
/// The arrows-then-Return drive in `SessionStore.answerPrompt` is right for claude and codex,
/// whose lists open on the plain answer. It is wrong for an agent whose list opens on a
/// DURABLE grant: grok's first permission card of a session focuses "Yes, and don't ask again
/// for anything (always-approve mode)" (probed live, grok 1.0.30), so any Return that lands
/// before the cursor has demonstrably moved grants always-approve. grok also numbers its rows
/// and picks-and-submits on the number, so the safe drive is shorter, not longer: read the row
/// whose label is the answer, press its key, done.
///
/// A sub-protocol checked with `as?` at the one call site, so claude's and codex's drivers —
/// and anything another track is building — are untouched by its existence.
@MainActor
protocol AgentKeyedDialogDriver: AgentDialogDriver {
    /// The key of the plain one-time approval ("Yes" and nothing more), or nil when the screen
    /// shows no such row. Read off the screen every time: grok's row ORDER differs between
    /// dialog kinds, so a remembered index is exactly the bug this type exists to avoid.
    func allowKey(inViewport viewport: String) -> Character?

    /// The key of option `index` of a single question, or nil unless that row reads `label`.
    /// The store's question answers go through `AgentKeyedQuestionDriver`'s checked program
    /// instead, which resolves the same printed key per step; this stays as the one-row lookup.
    func optionKey(_ index: Int, label: String, inViewport viewport: String) -> Character?
}

/// One keystroke of a keyed answer drive, as `SessionStore` sends it.
enum KeyedKeystroke: Equatable {
    /// A printable key as a key event (`sendCharacterKey`): a row's own key, or Space.
    case character(Character)
    case arrowUp
    case arrowDown
    /// Text for an open editor, as a bracketed paste (`sendText`).
    case paste(String)
    /// Return. Only ever planned to commit an editor's text — never on an option row, where
    /// it would submit whatever the cursor sits on.
    case returnKey
    /// Tab (`sendTab`): grok's way of handing a parked card its keyboard back.
    case tab
}

/// One step of a keyed drive over a set of questions: what the screen must show before the
/// step's keys go out, and the keys.
///
/// **Each step is checked against a fresh read of the screen and nothing is pressed unless it
/// matches**, because a keyed agent's digits COMMIT (grok's advance the question and submit on
/// the last one, facts-2 §0.3): a key that lands on the wrong question is an answer, not a
/// cursor move. A step that does not match aborts the drive with the dialog left for a person.
struct KeyedAnswerStep: Equatable {
    struct Expectation: Equatable {
        /// Which question of the set must be on screen, 0-based.
        let question: Int
        /// For a multi-select question, exactly which options must read checked; nil on a
        /// single-select question.
        let checked: Set<Int>?
        /// The free-text editor must be open and show this text (empty right after opening);
        /// nil means it must be closed.
        let editor: String?
    }

    enum Key: Equatable {
        /// The printed key of option N, read off the screen at the time of the step.
        case option(Int)
        /// The key that opens the free-text row.
        case freeText
        /// Toggle the focused checkbox.
        case toggle
        case up
        case down
        case paste(String)
        /// Commit the editor's text.
        case commitText
    }

    let expect: Expectation
    let keys: [Key]
}

/// Whole-set answers for a keyed agent: question sets, multi-select and typed answers.
@MainActor
protocol AgentKeyedQuestionDriver: AgentKeyedDialogDriver {
    /// The drive for these picks, or nil when the agent cannot take that shape — the store
    /// answers `unanswerable` then, before any key.
    func answerPlan(for questions: [PromptQuestion], picks: [[AnswerPlan.Pick]]) -> [KeyedAnswerStep]?

    /// The keystrokes for `step` on this screen, or nil when the screen is not what the step
    /// expects. Called on a fresh read before every step.
    func keystrokes(for step: KeyedAnswerStep, questions: [PromptQuestion],
                    inViewport viewport: String) -> [KeyedKeystroke]?
}

/// What dismissing a question card takes on the screen as read now. See
/// `AgentQuestionDismisser`.
enum QuestionDismissStep: Equatable {
    /// The card holds the keyboard: these keys dismiss it.
    case press([KeyedKeystroke])
    /// The card is up but its keyboard is parked elsewhere: these keys give it back, and the
    /// dismiss waits for a read that says they did.
    case refocus([KeyedKeystroke])
    /// The card is up in a state the dismiss cannot be keyed into (an open editor would take
    /// the key as text).
    case blocked
    /// No card of these questions is on screen.
    case absent

    /// A drive can begin from here: there is a key to send.
    var startsDismiss: Bool {
        switch self {
        case .press, .refocus: return true
        case .blocked, .absent: return false
        }
    }
}

/// **A question refused without cancelling the turn.**
///
/// The shared `deny` is one blind key, and for grok that key is Ctrl+C — which on a QUESTION
/// card cancels the agent's whole turn. grok has a gentler key for exactly this, Shift+x,
/// "Dismiss the question (the agent continues without an answer)" (probed live on 1.0.30: the
/// tool returns "User declined to answer the questions…" and the model goes on). Unlike
/// `deny`, the dismiss is read-guarded like the keyed answer drive: a key that lands in an
/// open editor or on another card is not a refusal, so the store reads before every press and
/// after the last one, and files `keyed-screen-mismatch` instead of pressing blind.
@MainActor
protocol AgentQuestionDismisser: AgentDialogDriver {
    /// The step for `questions`' card on this screen. `questions` nil (the abort path, which has
    /// no call to compare) accepts any question card.
    func dismissStep(for questions: [PromptQuestion]?, inViewport viewport: String) -> QuestionDismissStep
}
