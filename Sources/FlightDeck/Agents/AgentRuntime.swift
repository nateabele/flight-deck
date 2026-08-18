import Foundation

/// The observation half of an agent integration, kept off `AgentAdapter` because both
/// agents multiplex ONE app-wide source across N tabs: claude's status registry is a single
/// flat pid-keyed directory, and a codex app-server owns every thread it created. A
/// per-session runtime would re-scan the registry N times for claude and, for codex, lose
/// every thread the moment its short-lived process exited.
@MainActor
protocol AgentRuntime: AnyObject {
    func attach(_ binding: AgentBinding, onEvent: @escaping (AgentEvent) -> Void)
    func detach(_ binding: AgentBinding)
}
