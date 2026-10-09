import FleetKit
import Foundation

/// grok's permission and question cards, read and answered.
///
/// **Answered by key, never by Return** — see `AgentKeyedDialogDriver`. The probe established
/// all three facts this rests on (grok 1.0.30, facts §0.5 and §4): a digit picks AND submits
/// (`3` allowed a write, `4` rejected one); Return submits whatever row is focused; and the
/// first card of a session focuses always-approve, the next one whichever row was chosen last.
///
/// **Deny is Ctrl+C, not Escape.** grok's Escape on a card "parks focus in the scrollback. It
/// never answers or dismisses the request" (user guide ch. 3, and seen live); Ctrl+C cancels
/// the request. One key, no reading — the property `AgentDialogDriver.deny` asks for.
struct GrokDialogDriver: AgentKeyedQuestionDriver {
    func focusedRow(inViewport viewport: String) -> Int? {
        let rows = GrokScreen.cardRows(inViewport: viewport)
        let focused = rows.indices.filter { rows[$0].focused }
        return focused.count == 1 ? focused[0] : nil
    }

    func row(_ index: Int, reads label: String, inViewport viewport: String) -> Bool {
        let rows = GrokScreen.cardRows(inViewport: viewport)
        guard rows.indices.contains(index) else { return false }
        return GrokScreen.row(rows[index], reads: label)
    }

    func hasSelectList(inViewport viewport: String) -> Bool {
        !GrokScreen.cardRows(inViewport: viewport).isEmpty
    }

    /// Index 2 on the probed write card — always-approve, all-edits-this-session, Yes, No.
    /// **Stated for the protocol and used by nothing**: the keyed path in
    /// `SessionStore.answerPrompt` reads the "Yes" row off the screen instead (`allowKey`),
    /// because grok's bash cards order their rows differently (user guide ch. 5) and an index
    /// that is right for one card kind is a durable grant on another.
    let allowRow = 2

    func deny(_ injector: TextInjecting) { injector.sendControlKey("c") }

    /// The one row whose label is exactly `Yes`. Exactly one, so a card this build misreads —
    /// two such rows, or none — refuses rather than guesses.
    func allowKey(inViewport viewport: String) -> Character? {
        let yes = GrokScreen.cardRows(inViewport: viewport).filter { $0.label == "Yes" }
        guard yes.count == 1, yes[0].key.isNumber else { return nil }
        return yes[0].key
    }

    /// The row's own printed key, never `index + 1`: a question card keys rows `1`–`9` then
    /// `a`–`f`. The free-text row (`z`) is not an option and is never returned.
    func optionKey(_ index: Int, label: String, inViewport viewport: String) -> Character? {
        let rows = GrokScreen.cardRows(inViewport: viewport).filter { $0.key != "z" }
        guard rows.indices.contains(index), GrokScreen.row(rows[index], reads: label) else { return nil }
        return rows[index].key
    }

    /// A question set, a checkbox question or a typed answer, keyed — see `GrokAnswerPlan`.
    func answerPlan(for questions: [PromptQuestion], picks: [[AnswerPlan.Pick]]) -> [KeyedAnswerStep]? {
        GrokAnswerPlan.plan(for: questions, picks: picks)
    }

    func keystrokes(for step: KeyedAnswerStep, questions: [PromptQuestion],
                    inViewport viewport: String) -> [KeyedKeystroke]? {
        GrokAnswerPlan.keystrokes(for: step, questions: questions, inViewport: viewport)
    }
}
