import Foundation

/// One project's swarm as a client sees it (L3-S §8). This is the only place an account's
/// display name travels on the fleet wire — never its id, never its home, which is what keeps
/// `FleetAccountEmissionTests` true for everything else.
public struct WireSwarm: Codable, Equatable, Sendable {
    public var state: String
    public var summary: String
    public var banner: String?
    public var agents: [WireSwarmAgent]
    public var meters: [WireSwarmMeter]
    public var waiting: Int
    public init(state: String, summary: String, banner: String?, agents: [WireSwarmAgent], meters: [WireSwarmMeter], waiting: Int) {
        self.state = state; self.summary = summary; self.banner = banner; self.agents = agents
        self.meters = meters; self.waiting = waiting
    }
}

public struct WireSwarmAgent: Codable, Equatable, Hashable, Sendable, Identifiable {
    public var session: UUID
    public var task: String?
    public var kind: String
    public var model: String
    public var accountName: String?
    public var state: String
    public var marker: String?
    public var contested: Bool
    public var handoffPending: Bool
    public var id: UUID { session }
    public init(session: UUID, task: String?, kind: String, model: String, accountName: String?, state: String,
                marker: String?, contested: Bool, handoffPending: Bool) {
        self.session = session; self.task = task; self.kind = kind; self.model = model; self.accountName = accountName
        self.state = state; self.marker = marker; self.contested = contested; self.handoffPending = handoffPending
    }
}

public struct WireSwarmMeter: Codable, Equatable, Hashable, Sendable {
    public var pool: String
    public var accountName: String
    public var utilization: Double?
    public var state: String
    public init(pool: String, accountName: String, utilization: Double?, state: String) {
        self.pool = pool; self.accountName = accountName; self.utilization = utilization; self.state = state
    }
}
