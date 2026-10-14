import Foundation

/// The words an agent is held to in everything it writes. The people reading a plan, a triage
/// reason or a question see the agent's text verbatim, and they call the project's work items
/// tasks — so every prompt Flight Deck sends tells the agent the same, and none of them says the
/// older name itself (an agent that never reads it has nothing to echo).
///
/// Every prompt builder in `Triage`, `RoundPrompts` and `SchemaRepair` ends with `rule`; the
/// guard test builds them all and fails on any that doesn't, so a new prompt can't leave it out.
public enum AgentVocabulary {
    /// One line, appended to every agent-facing prompt. Names the `br` CLI because its output is
    /// the one place an agent can still meet the old word, and says not to repeat it.
    public static let rule = "Call the project's work items tasks, and the whole set the task graph. " +
        "The `br` command's output uses an older name for them: never repeat it in anything you write — say task."

    /// `prompt` followed by `rule`, on its own paragraph.
    static func closing(_ prompt: String) -> String { prompt + "\n\n" + rule }
}
