import Foundation

/// One of a claude conversation's background agents, as the phone sees it.
///
/// `state` is a string, not an enum, for the reason `WireSession.activity` is: a Mac newer
/// than this phone may grow a fourth state, and a closed enum would turn that into a decode
/// failure for the whole snapshot. A phone renders an unknown state as `running`.
public struct WireSubagent: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let parent: String?
    public let type: String
    public let description: String
    /// `"running"` | `"blocked"` | `"done"`; anything else renders as running.
    public let state: String

    public init(id: String, parent: String?, type: String, description: String, state: String) {
        self.id = id
        self.parent = parent
        self.type = type
        self.description = description
        self.state = state
    }
}

extension WireSession {
    /// The agent whose dialog `openPromptCall` names, when it is a subagent's rather than the
    /// conversation's own. Resolved through `subagents` so a phone that was told an id the
    /// tree does not hold (a tree update still in flight) gets nil, not a dangling reference.
    public var blockedSubagent: WireSubagent? {
        guard let agent = openPromptAgent else { return nil }
        return subagents?.first { $0.id == agent }
    }
}
