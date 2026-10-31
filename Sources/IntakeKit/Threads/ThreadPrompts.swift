import Foundation

/// What a thread turn says to its agent. The first turn carries only the outline, the anchor
/// and its section, and an index of the other workspace files (D6): the agent opens what it
/// needs. Later turns resume the session, so they carry only what is new.
public enum ThreadPrompts {
    /// The prompt for `turn`. `earlier` is the thread's turns before it, which hold the
    /// questions an answer refers to. `moved` is set when a resumed session last read an older
    /// version: section ids changed under it, so the outline is sent again.
    public static func turn(record: ThreadRecord, turn: ThreadTurn, earlier: [ThreadTurn], workspace: ThreadWorkspace,
                            moved: Bool, diffs: [ThreadDiff]) -> String {
        let human = message(turn, earlier: earlier, diffs: diffs)
        guard record.sessionID != nil else { return first(record: record, workspace: workspace, message: human) }
        guard moved else { return human }
        return """
        The plan moved on: it is now checkpoint \(workspace.checkpoint) (\(workspace.label)). Your workspace at \
        \(workspace.directory.path) was rebuilt from it, and section ids now name this version's sections. Quote \
        checkpoint \(workspace.checkpoint) in any proposeDiff.

        \(workspace.outline)
        \(human)
        """
    }

    static func first(record: ThreadRecord, workspace: ThreadWorkspace, message: String) -> String {
        let dir = workspace.directory.path
        let reads = HeadlessCommand.threadReadsFilesOnly(record.agent)
            ? "You can read files; you have no shell in this thread."
            : "You can read files and run reading commands: " + HeadlessCommand.threadReadCommands.joined(separator: ", ")
                + ". Nothing you run may change a file."
        let index = workspace.files.map { "- \(dir)/\($0)" }.joined(separator: "\n")
        return """
        You are answering the human in an ask thread about a plan that Flight Control is shaping. \
        \(AgentVocabulary.rule)

        The working directory is the project's repository. \(reads)

        The plan is checkpoint \(workspace.checkpoint) (\(workspace.label)). Its files are in \(dir):

        \(workspace.outline)
        \(workspace.anchorText)
        Other files, to open only when you need them:
        \(index)

        The provenance files list what each round recorded about the anchored section, each item with an id. \
        Cite an item as [cite:<id>].

        Answer in the schema:
        - reply: markdown for the human, with citations.
        - decision: 0–3 lines on what was decided in this turn, or empty.
        - actions, each with every field present and the ones its op doesn't use null:
          - proposeDiff: a change to the plan. checkpoint is \(workspace.checkpoint); quote is the plan's exact \
        words, found exactly once (give prefix and suffix context when the words occur more than once); \
        replacement is the new text. The human accepts or rejects it.
          - addNote: a note for the next round, of kind comment, mustChange, delete or replace, anchored on a \
        quote of checkpoint \(workspace.checkpoint) or with a null anchor for the whole plan.
          - askQuestion: a question for the human to answer by choosing; ids must be unique.

        The human says:
        \(message)
        """
    }

    /// What went wrong with the last answer, for a retry on the same session.
    public static func retry(_ errors: [String]) -> String {
        """
        Your answer was not applied:
        \(errors.map { "- \($0)" }.joined(separator: "\n"))

        Fix those actions and send the whole answer again.
        """
    }

    /// The human's side of a turn: their words, their answers to the questions an earlier turn
    /// asked, or the stale change a repropose is for.
    static func message(_ turn: ThreadTurn, earlier: [ThreadTurn], diffs: [ThreadDiff]) -> String {
        var parts: [String] = []
        if let you = turn.you { parts.append(you) }
        if let answers = turn.answers, !answers.isEmpty {
            let asked = earlier.flatMap(\.actions).compactMap { action -> StructuredQuestion? in
                if case .askQuestion(let q) = action { return q } else { return nil }
            }
            parts.append(answers.map { a in
                guard let q = asked.last(where: { $0.id == a.questionID }) else { return "\(a.questionID): \(a.selected)" }
                return "Q: \(q.text)\nA: \(q.render(a))"
            }.joined(separator: "\n\n"))
        }
        if let id = turn.reproposedDiff, let diff = diffs.first(where: { $0.id == id }) {
            parts.append("""
            The change you proposed earlier no longer applies to the current version:
            Replace:
            \(diff.old)
            With:
            \(diff.new)
            """)
        }
        return parts.joined(separator: "\n\n")
    }
}
