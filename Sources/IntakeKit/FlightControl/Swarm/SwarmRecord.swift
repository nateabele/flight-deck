import Foundation

/// One swarm's lifecycle. `paused` and `draining` both stop new claims; `draining` additionally
/// becomes `stopped` when the last working agent goes idle. A swarm restored after a relaunch is
/// always `paused` (spec §2) — FD never resumes claiming on its own.
public enum SwarmState: String, Codable, Sendable, Equatable { case running, paused, draining, stopped }

/// `done` is an agent that has left the swarm for good (its tab closed, or the swarm stopped);
/// `handedOff` is one whose work moved to a fresh agent (L3-U).
public enum SwarmAgentState: String, Codable, Sendable, Equatable { case starting, working, idle, handedOff, done }

/// Which ready tasks a swarm may claim. An intake swarm carries the task ids its release
/// created, resolved once at launch, so the controller never needs the intake store to tick.
public enum SwarmFilter: Equatable, Sendable {
    case intake(id: UUID, tasks: [String])
    case allReady

    public func admits(_ task: String) -> Bool {
        switch self {
        case .allReady: true
        case .intake(_, let tasks): tasks.contains(task)
        }
    }
}

extension SwarmFilter: Codable {
    private enum Keys: String, CodingKey { case intake, tasks, allReady }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        if let id = try c.decodeIfPresent(UUID.self, forKey: .intake) {
            self = .intake(id: id, tasks: try c.decodeIfPresent([String].self, forKey: .tasks) ?? [])
        } else if try c.decodeIfPresent(Bool.self, forKey: .allReady) == true {
            self = .allReady
        } else {
            // Refused rather than defaulted to `allReady`: a filter that lost its intake and
            // silently widened to the whole project would claim work nobody released.
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "filter names neither an intake nor allReady"))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        switch self {
        case .intake(let id, let tasks):
            try c.encode(id, forKey: .intake)
            try c.encode(tasks, forKey: .tasks)
        case .allReady:
            try c.encode(true, forKey: .allReady)
        }
    }
}

/// `harness|model|knobs|pool`. Two agents with equal keys are interchangeable for reuse (spec §2).
/// Knobs are sorted so a block written `{effort, agent}` and one written `{agent, effort}` are the
/// same configuration — a map's iteration order must never decide whether an agent is reused.
public struct ConfigKey: RawRepresentable, Hashable, Codable, Sendable, CustomStringConvertible {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ block: ExecutionBlock) {
        let knobs = block.knobs.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")
        rawValue = [block.harness.rawValue, block.model, knobs, block.pool.rawValue].joined(separator: "|")
    }
    public var description: String { rawValue }
}

/// An execution block persisted through the same codec br's `agent_context` uses, so a stored
/// block and a task's block can never disagree about a field.
public struct StoredBlock: Codable, Equatable, Sendable {
    public var block: ExecutionBlock
    public init(_ block: ExecutionBlock) { self.block = block }

    public init(from decoder: Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        switch ExecutionBlockCodec.decode(agentContext: text) {
        case .success(let block?): self.block = block
        case .success(nil):
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "no execution block"))
        case .failure(let error):
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: error.message))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(try ExecutionBlockCodec.encode(block, into: nil))
    }
}

/// `AccountLease` is not `Codable` in the contract; this is its persisted shape.
public struct StoredLease: Codable, Equatable, Sendable {
    public var id: UUID
    public var pool: PoolID
    public var account: AccountRef
    public init(_ lease: AccountLease) { id = lease.id; pool = lease.pool; account = lease.account }
    public var lease: AccountLease { AccountLease(id: id, pool: pool, account: account) }
}

public struct SwarmAgentRecord: Codable, Equatable, Sendable {
    public var session: UUID
    public var agentName: String
    public var config: ConfigKey
    public var block: StoredBlock
    public var lease: StoredLease?
    public var task: String?
    public var state: SwarmAgentState
    /// Written and saved BEFORE `br update --claim` runs, cleared once its outcome is recorded.
    /// A crash between the claim landing and the record being saved leaves this set, which is
    /// how a restore finds out whether to adopt the claim (Review Focus: crash mid-claim).
    public var pendingClaim: String?
    /// Set when this agent must never be reused again: its context reset failed, or it never
    /// showed a composer (spec §10).
    public var excludedFromReuse: Bool
    /// A short human note for the row: "stuck at start", "reset failed", "tab closed".
    public var marker: String?
    /// The last task this agent closed — what the row's *done* marker names.
    public var lastTask: String?
    public var stateSince: Date
    public var handedOffFrom: UUID?
    public var handedOffTo: UUID?

    public init(session: UUID, agentName: String, block: ExecutionBlock, lease: AccountLease?,
                task: String?, state: SwarmAgentState, stateSince: Date) {
        self.session = session; self.agentName = agentName
        self.config = ConfigKey(block); self.block = StoredBlock(block)
        self.lease = lease.map(StoredLease.init); self.task = task; self.state = state
        self.pendingClaim = nil; self.excludedFromReuse = false; self.marker = nil
        self.lastTask = nil; self.stateSince = stateSince
        self.handedOffFrom = nil; self.handedOffTo = nil
    }
}

public struct WaitingTask: Codable, Equatable, Sendable {
    public var task: String
    public var reason: String
    public init(task: String, reason: String) { self.task = task; self.reason = reason }
}

/// At most one per project (spec §2).
public struct SwarmRecord: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    /// The standardized project path (`FlywheelObserveService.key`).
    public var project: String
    public var cap: Int
    /// Pool id → its own cap. A dictionary keyed by `String` rather than `PoolID` so it encodes
    /// as a JSON object: `JSONEncoder` writes a non-`String`-keyed dictionary as an array.
    public var poolCaps: [String: Int]
    public var filter: SwarmFilter
    public var state: SwarmState
    public var agents: [SwarmAgentRecord]
    public var createdAt: Date
    /// The header banner: the restart notice, or why the swarm paused itself.
    public var banner: String?
    /// Tasks the last fill could not start, with why (spec §4 step 3).
    public var waiting: [WaitingTask]
    /// Ready tasks whose block cannot be routed (spec §10). Kept apart from `waiting` because
    /// they never count against auto-stop: a swarm whose only ready work is unroutable is done.
    public var unroutable: [WaitingTask]
    /// Config key → consecutive spawn failures (spec §10: three in a row pause the swarm).
    public var spawnFailures: [String: Int]

    public init(id: UUID, project: String, cap: Int, poolCaps: [String: Int], filter: SwarmFilter,
                state: SwarmState, agents: [SwarmAgentRecord], createdAt: Date) {
        self.id = id; self.project = project; self.cap = cap; self.poolCaps = poolCaps
        self.filter = filter; self.state = state; self.agents = agents; self.createdAt = createdAt
        self.banner = nil; self.waiting = []; self.unroutable = []; self.spawnFailures = [:]
    }

    public func agent(_ session: UUID) -> SwarmAgentRecord? { agents.first { $0.session == session } }

    public mutating func update(_ session: UUID, _ change: (inout SwarmAgentRecord) -> Void) {
        guard let i = agents.firstIndex(where: { $0.session == session }) else { return }
        change(&agents[i])
    }

    /// Agents that fill a slot: the spec's free-slot count is `cap` minus these.
    public var activeCount: Int { agents.filter { $0.state == .starting || $0.state == .working }.count }

    public func load(of pool: PoolID) -> Int {
        agents.filter { ($0.state == .starting || $0.state == .working) && $0.block.block.pool == pool }.count
    }

    public func poolCap(_ pool: PoolID) -> Int? { poolCaps[pool.rawValue] }
}

/// One line of `swarm-log/<swarm id>.jsonl` (spec §2).
public struct SwarmLogEntry: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case launch, claim, conflict, spawn, spawnFailed, reuse, resetFailed, prompt, stuck
        case close, reopen, released, handoff, spill, pause, resume, drain, stop, error
    }
    public var at: Date
    public var kind: Kind
    public var task: String?
    public var session: UUID?
    public var detail: String
    public init(at: Date, kind: Kind, task: String? = nil, session: UUID? = nil, detail: String = "") {
        self.at = at; self.kind = kind; self.task = task; self.session = session; self.detail = detail
    }
}
