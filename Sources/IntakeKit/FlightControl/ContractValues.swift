import Foundation

public struct ModelEntry: Codable, Hashable, Sendable {
    public var id: String
    public var displayName: String
    /// Knob names this model accepts; values come from the catalog's `knobSchema`.
    public var knobs: [String]
    public init(id: String, displayName: String, knobs: [String]) { self.id = id; self.displayName = displayName; self.knobs = knobs }
}

public struct AdapterCatalog: Codable, Equatable, Sendable {
    public var harness: HarnessID
    public var models: [ModelEntry]
    /// Knob name → allowed values, as the adapter declares them.
    public var knobSchema: [String: [String]]
    public var defaultModel: String?
    public var enabled: Bool
    public init(harness: HarnessID, models: [ModelEntry], knobSchema: [String: [String]], defaultModel: String?, enabled: Bool) {
        self.harness = harness; self.models = models; self.knobSchema = knobSchema
        self.defaultModel = defaultModel; self.enabled = enabled
    }
}

public struct AdapterCatalogs: Equatable, Sendable {
    public var byHarness: [HarnessID: AdapterCatalog]
    /// Insertion order, so "ties go to catalog order" (L3-I §6) is stable.
    public var order: [HarnessID]

    public init(_ catalogs: [AdapterCatalog]) {
        byHarness = Dictionary(catalogs.map { ($0.harness, $0) }, uniquingKeysWith: { a, _ in a })
        // First occurrence wins, matching `byHarness`; a repeat would list its models twice.
        var seen = Set<HarnessID>()
        order = catalogs.map(\.harness).filter { seen.insert($0).inserted }
    }

    public func contains(_ ref: ModelRef) -> Bool {
        byHarness[ref.harness]?.models.contains { $0.id == ref.model } ?? false
    }

    public func knobsValid(_ ref: ModelRef) -> Bool {
        guard let cat = byHarness[ref.harness], let entry = cat.models.first(where: { $0.id == ref.model }) else { return false }
        for (k, v) in ref.knobs {
            guard entry.knobs.contains(k), cat.knobSchema[k]?.contains(v) == true else { return false }
        }
        return true
    }

    public var enabledModels: [ModelRef] {
        order.compactMap { byHarness[$0] }.filter(\.enabled)
            .flatMap { cat in cat.models.map { ModelRef(harness: cat.harness, model: $0.id) } }
    }
}

public struct Assignment: Equatable, Sendable {
    public var block: ExecutionBlock
    public init(block: ExecutionBlock) { self.block = block }

    /// `Router.assign` cannot fail, so this is the shared way for every branch to say "no route".
    /// A writer never stores an unroutable block (the codec refuses empty fields anyway).
    public static func unroutable(kind: KindID, reason: String, at: Date) -> Assignment {
        Assignment(block: ExecutionBlock(kind: kind, harness: "", model: "", knobs: [:], pool: "",
                                         source: AssignmentSource(by: .default, ruleId: nil, reason: "unroutable: \(reason)", at: at),
                                         pinned: false))
    }

    public var isUnroutable: Bool { block.harness.rawValue.isEmpty || block.model.isEmpty || block.pool.rawValue.isEmpty }

    public var unroutableReason: String? {
        guard isUnroutable else { return nil }
        let prefix = "unroutable: "
        let r = block.source.reason
        return r.hasPrefix(prefix) ? String(r.dropFirst(prefix.count)) : r
    }
}

public struct ScoredModel: Equatable, Sendable {
    public var model: ModelRef
    public var score: Double
    public var confidence: Double
    public init(model: ModelRef, score: Double, confidence: Double) { self.model = model; self.score = score; self.confidence = confidence }
}

public enum HeadroomState: String, Codable, Sendable { case underSoft, overSoft, overHard, unknown }

/// An account as Level 3 sees it. `id == nil` is a slot in a local pool, which has no account.
///
/// Identity is harness + id. A rename changes `label`, and a renamed account must still match its
/// leases and readings. A slot with no id has nothing else to go on, so it compares by label.
public struct AccountRef: Codable, Hashable, Sendable {
    public var harness: HarnessID
    public var id: UUID?
    public var label: String
    public init(harness: HarnessID, id: UUID?, label: String) { self.harness = harness; self.id = id; self.label = label }

    public static func == (a: AccountRef, b: AccountRef) -> Bool {
        guard a.harness == b.harness, a.id == b.id else { return false }
        return a.id != nil || a.label == b.label
    }
    public func hash(into hasher: inout Hasher) {
        hasher.combine(harness)
        if let id { hasher.combine(id) } else { hasher.combine(label) }
    }
}

public struct AccountHeadroom: Equatable, Sendable {
    public var account: AccountRef
    public var worstUtilization: Double?
    public var state: HeadroomState
    public var resetsAt: Date?
    public init(account: AccountRef, worstUtilization: Double?, state: HeadroomState, resetsAt: Date?) {
        self.account = account; self.worstUtilization = worstUtilization; self.state = state; self.resetsAt = resetsAt
    }
}

public struct AccountLease: Hashable, Sendable {
    public var id: UUID
    public var pool: PoolID
    public var account: AccountRef
    public init(id: UUID = UUID(), pool: PoolID, account: AccountRef) { self.id = id; self.pool = pool; self.account = account }
}

public struct UsageWindow: Codable, Equatable, Sendable {
    public var name: String
    /// 0...1; may exceed 1 on an exceeded spend limit.
    public var utilization: Double
    public var resetsAt: Date?
    public init(name: String, utilization: Double, resetsAt: Date?) { self.name = name; self.utilization = utilization; self.resetsAt = resetsAt }
}

public struct UsageReading: Codable, Equatable, Sendable {
    public var account: AccountRef
    public var windows: [UsageWindow]
    public var readAt: Date
    public var source: String
    /// A real rejection (429, `rate_limit_exceeded`, a non-allowed `rate_limit_event`). It puts
    /// the account over hard whatever its windows say.
    public var hardRejection: Bool
    public init(account: AccountRef, windows: [UsageWindow], readAt: Date, source: String, hardRejection: Bool) {
        self.account = account; self.windows = windows; self.readAt = readAt; self.source = source; self.hardRejection = hardRejection
    }
    public var worstWindow: UsageWindow? { windows.max { $0.utilization < $1.utilization } }
}

public struct TranscriptPointer: Codable, Equatable, Sendable {
    public enum Locator: Codable, Equatable, Sendable { case path(String), command(String) }
    public var locator: Locator
    public var format: String
    public var howToRead: String
    public init(locator: Locator, format: String, howToRead: String) { self.locator = locator; self.format = format; self.howToRead = howToRead }
}

public struct TaskRef: Codable, Hashable, Sendable {
    public var id: String
    public var project: URL
    public init(id: String, project: URL) { self.id = id; self.project = project }
}

public struct SessionRef: Codable, Hashable, Sendable {
    public var id: UUID
    public var agentName: String?
    public init(id: UUID, agentName: String?) { self.id = id; self.agentName = agentName }
}

public struct SwarmAgentSnapshot: Equatable, Sendable {
    public var session: SessionRef
    public var agentName: String
    public var block: ExecutionBlock
    public var lease: AccountLease?
    public var task: TaskRef?
    public init(session: SessionRef, agentName: String, block: ExecutionBlock, lease: AccountLease?, task: TaskRef?) {
        self.session = session; self.agentName = agentName; self.block = block; self.lease = lease; self.task = task
    }
}

public struct HandoffRequest: Equatable, Sendable {
    public var task: TaskRef
    public var block: ExecutionBlock
    public var oldAgent: String
    public var oldSession: SessionRef
    public var transcript: TranscriptPointer?
    public var reservedFiles: [String]
    /// True when `reservedFiles` is empty because nobody could read the reservations, not
    /// because the agent held none. Set by the driver; the prompt then says so instead of
    /// claiming "held no file reservations". Not an init parameter, so the contract's init is unchanged.
    public var reservationsUnknown = false
    public var fromAccount: AccountRef
    public init(task: TaskRef, block: ExecutionBlock, oldAgent: String, oldSession: SessionRef,
                transcript: TranscriptPointer?, reservedFiles: [String], fromAccount: AccountRef) {
        self.task = task; self.block = block; self.oldAgent = oldAgent; self.oldSession = oldSession
        self.transcript = transcript; self.reservedFiles = reservedFiles; self.fromAccount = fromAccount
    }
}

public enum SpawnError: Error, Equatable, Sendable {
    case launchFailed(String), composerTimeout, unsupportedHarness(HarnessID), claimConflict(String)
}

public struct PoolSummary: Codable, Hashable, Sendable {
    public var id: PoolID
    public var harness: HarnessID
    public var label: String
    public init(id: PoolID, harness: HarnessID, label: String) { self.id = id; self.harness = harness; self.label = label }
}
