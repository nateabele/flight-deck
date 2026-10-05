import Foundation
import IntakeKit

/// What intake release asks for before it writes tasks: each created task's routed
/// `agent_context`, keyed by temp id (spec L3-R §4). `RoutingService` conforms. A host with no
/// routing — every store a test builds — releases exactly as before Level 3.
@MainActor
protocol EncodeRoutingProviding: AnyObject {
    func agentContexts(for steps: [ApplyStep], project: String) async -> [String: String]
}
