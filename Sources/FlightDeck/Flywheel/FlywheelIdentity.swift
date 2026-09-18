import Foundation

/// The Agent-Mail identity a booted flywheel agent runs under, and the environment
/// delta that identity implies for the spawned process.
///
/// `am macros start-session` is the source of truth for `agentName` — it is the piece
/// that actually registers the identity with Agent-Mail — so this struct never invents
/// one; `FlywheelCoordinator.boot` decodes it from that command's JSON output.
struct FlywheelIdentity: Equatable, Sendable {
    let agentName: String
    let project: String

    /// The environment variables a spawned agent process needs to act as this
    /// identity: its own name (for prompts/logging) and the two Agent-Mail variables
    /// that let its CLI find the right inbox.
    var environment: [String: String] {
        [
            "AGENT_NAME": agentName,
            "AGENT_MAIL_AGENT": agentName,
            "AGENT_MAIL_PROJECT": project,
        ]
    }
}
