import FleetKit
import SwiftUI

/// Every string the phone's swarm views show. Pure, so the decode and the copy are tested
/// without a simulator screen.
enum SwarmStyle {
    static func agent(for session: UUID, in project: WireProject) -> WireSwarmAgent? {
        project.swarm?.agents.first { $0.session == session }
    }
    static func chip(_ agent: WireSwarmAgent) -> String? { agent.task.map { "\($0) · \(agent.kind)" } }
    static func detail(_ agent: WireSwarmAgent) -> String { [agent.model, agent.accountName].compactMap { $0 }.joined(separator: " · ") }
    static func cardTitle(_ swarm: WireSwarm) -> String { swarm.banner ?? swarm.summary }
    static func canPause(_ swarm: WireSwarm) -> Bool { swarm.state == "running" || swarm.state == "draining" }
    /// Draining is the one state with both: stop the drain by resuming, or finish pausing now.
    static func canResume(_ swarm: WireSwarm) -> Bool { swarm.state == "paused" || swarm.state == "draining" }
    static func meterText(_ meter: WireSwarmMeter) -> String {
        "\(meter.pool) · \(meter.accountName) · " + (meter.utilization.map { "\(Int(($0 * 100).rounded()))%" } ?? "no reading")
    }
}
