import Foundation

/// The values a tool's command template can interpolate, for one selected session.
///
/// A plain value type on purpose: it holds no adapter, no store and no view, which is what
/// lets `ToolTemplate` be a pure function and lets these tests run without a window.
///
/// The first three fields come from `AgentAdapter.location(for:)` — never from `Session`
/// directly, see `SessionStore.toolContext()`. The rest are Flight Deck's own facts about the
/// tab and the project it is filed under, which no agent has an opinion about.
struct ToolContext: Equatable {
    /// Where the agent is working right now, worktree included.
    var workingDirectory: String
    /// The project root the tab is filed under. Differs from `workingDirectory` in a worktree.
    var projectPath: String
    var projectName: String
    var sessionTitle: String
    var agent: AgentID
    var conversationID: UUID
    /// Optional because `AgentBinding.transcriptURL` is: an agent that reports no transcript
    /// is still usable. See `ToolTemplate.expand` for why this expands to `''`, not to "".
    var transcriptPath: String?
    var home: String = NSHomeDirectory()
}
