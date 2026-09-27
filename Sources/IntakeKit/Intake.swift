import Foundation

public enum Preset: String, Codable, Sendable { case bead, sketch, featurePlan, fullPlan }

public enum IntakeState: String, Codable, Sendable {
    case triaging, needsAnswers, awaitingChoice, parked, review, releasing, released
    case partiallyReleased, failed, interrupted, discarded

    public var needsAttention: Bool {
        switch self {
        case .needsAnswers, .awaitingChoice, .review, .partiallyReleased, .failed, .interrupted:
            true
        default:
            false
        }
    }
}

public enum Harness: String, Codable, Sendable { case codex, claude }

public struct HarnessSession: Codable, Equatable, Sendable {
    public var harness: Harness
    public var sessionID: String
    public var model: String
    public var effort: String
    public init(harness: Harness, sessionID: String, model: String, effort: String) {
        self.harness = harness
        self.sessionID = sessionID
        self.model = model
        self.effort = effort
    }
}

public struct TriageExchange: Codable, Equatable, Sendable {
    public var questions: [String]
    public var answers: [String]?
    public init(questions: [String], answers: [String]? = nil) {
        self.questions = questions
        self.answers = answers
    }
}

public struct ReleaseRecord: Codable, Equatable, Sendable {
    public var releasedAt: Date
    public var appliedSteps: Int
    public var idMap: [String: String]
    public var error: String?
    public init(releasedAt: Date, appliedSteps: Int, idMap: [String: String], error: String? = nil) {
        self.releasedAt = releasedAt
        self.appliedSteps = appliedSteps
        self.idMap = idMap
        self.error = error
    }
}

public struct Intake: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var projectPath: String
    public var intent: String
    public var createdAt: Date
    public var state: IntakeState
    public var recommended: Preset?
    public var recommendationReason: String?
    public var triage: HarnessSession?
    public var exchanges: [TriageExchange]
    public var changeSet: ChangeSet?
    public var failure: String?
    public var rawFailureOutput: String?
    public var release: ReleaseRecord?
    public var ratingOverrides: [Int: DeliveryRating]
    public var droppedOps: Set<Int>
    public var confirmedDrift: Set<Int>

    public init(
        projectPath: String,
        intent: String,
        createdAt: Date = Date()
    ) {
        self.id = UUID()
        self.projectPath = projectPath
        self.intent = intent
        // Round to milliseconds: ISO8601 with fractional seconds preserves millisecond precision.
        // Sub-millisecond precision is lost in the round-trip, so we truncate to ensure
        // save/load equality and reliable newest-first ordering across multiple intakes.
        let interval = createdAt.timeIntervalSince1970
        let rounded = (interval * 1000).rounded() / 1000
        self.createdAt = Date(timeIntervalSince1970: rounded)
        self.state = .triaging
        self.recommended = nil
        self.recommendationReason = nil
        self.triage = nil
        self.exchanges = []
        self.changeSet = nil
        self.failure = nil
        self.rawFailureOutput = nil
        self.release = nil
        self.ratingOverrides = [:]
        self.droppedOps = Set<Int>()
        self.confirmedDrift = Set<Int>()
    }

    enum CodingKeys: String, CodingKey {
        case id, projectPath, intent, createdAt, state, recommended, recommendationReason
        case triage, exchanges, changeSet, failure, rawFailureOutput, release
        case ratingOverrides, droppedOps, confirmedDrift
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        projectPath = try container.decode(String.self, forKey: .projectPath)
        intent = try container.decode(String.self, forKey: .intent)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        state = try container.decode(IntakeState.self, forKey: .state)
        recommended = try container.decodeIfPresent(Preset.self, forKey: .recommended)
        recommendationReason = try container.decodeIfPresent(String.self, forKey: .recommendationReason)
        triage = try container.decodeIfPresent(HarnessSession.self, forKey: .triage)
        exchanges = try container.decodeIfPresent([TriageExchange].self, forKey: .exchanges) ?? []
        changeSet = try container.decodeIfPresent(ChangeSet.self, forKey: .changeSet)
        failure = try container.decodeIfPresent(String.self, forKey: .failure)
        rawFailureOutput = try container.decodeIfPresent(String.self, forKey: .rawFailureOutput)
        release = try container.decodeIfPresent(ReleaseRecord.self, forKey: .release)
        ratingOverrides = try container.decodeIfPresent([Int: DeliveryRating].self, forKey: .ratingOverrides) ?? [:]
        let droppedOpsArray = try container.decodeIfPresent([Int].self, forKey: .droppedOps) ?? []
        droppedOps = Set(droppedOpsArray)
        let confirmedDriftArray = try container.decodeIfPresent([Int].self, forKey: .confirmedDrift) ?? []
        confirmedDrift = Set(confirmedDriftArray)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(projectPath, forKey: .projectPath)
        try container.encode(intent, forKey: .intent)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(state, forKey: .state)
        try container.encodeIfPresent(recommended, forKey: .recommended)
        try container.encodeIfPresent(recommendationReason, forKey: .recommendationReason)
        try container.encodeIfPresent(triage, forKey: .triage)
        try container.encode(exchanges, forKey: .exchanges)
        try container.encodeIfPresent(changeSet, forKey: .changeSet)
        try container.encodeIfPresent(failure, forKey: .failure)
        try container.encodeIfPresent(rawFailureOutput, forKey: .rawFailureOutput)
        try container.encodeIfPresent(release, forKey: .release)
        if !ratingOverrides.isEmpty {
            try container.encode(ratingOverrides, forKey: .ratingOverrides)
        }
        let droppedOpsArray = Array(droppedOps).sorted()
        if !droppedOpsArray.isEmpty {
            try container.encode(droppedOpsArray, forKey: .droppedOps)
        }
        let confirmedDriftArray = Array(confirmedDrift).sorted()
        if !confirmedDriftArray.isEmpty {
            try container.encode(confirmedDriftArray, forKey: .confirmedDrift)
        }
    }
}
