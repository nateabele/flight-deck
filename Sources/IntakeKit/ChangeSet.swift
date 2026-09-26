import Foundation

public enum BeadRef: Hashable, Sendable, Codable {
    case existing(String)
    case new(String)

    public init(parsing raw: String) {
        self = raw.hasPrefix("new:") ? .new(String(raw.dropFirst(4))) : .existing(raw)
    }
    public var wireValue: String {
        switch self { case .existing(let id): id; case .new(let t): "new:\(t)" }
    }
    public init(from decoder: Decoder) throws {
        self.init(parsing: try decoder.singleValueContainer().decode(String.self))
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer(); try c.encode(wireValue)
    }
}

public enum EdgeKind: String, Codable, Sendable { case blocks, related, parentChild = "parent-child" }

public struct Precondition: Codable, Equatable, Sendable {
    public var status: String
    public var assignee: String?
    public init(status: String, assignee: String?) { self.status = status; self.assignee = assignee }
}

public enum DeliveryRating: String, Codable, Sendable, CaseIterable { case clarifying, scopeChange, invalidating }

public struct Delivery: Codable, Equatable, Sendable {
    public var rating: DeliveryRating
    public var reason: String
    public init(rating: DeliveryRating, reason: String) { self.rating = rating; self.reason = reason }
}

public struct FieldSet: Codable, Equatable, Sendable {
    public var title: String?
    public var description: String?
    public var acceptance: String?
    public var priority: Int?
    public init(title: String? = nil, description: String? = nil, acceptance: String? = nil, priority: Int? = nil) {
        self.title = title; self.description = description; self.acceptance = acceptance; self.priority = priority
    }
    public var isEmpty: Bool { title == nil && description == nil && acceptance == nil && priority == nil }
}

public struct NewBead: Codable, Equatable, Sendable {
    public var tempId: String
    public var title: String
    public var type: String
    public var priority: Int
    public var description: String
    public var acceptance: String?
    public var labels: [String]
    public init(tempId: String, title: String, type: String = "task", priority: Int = 2,
                description: String, acceptance: String? = nil, labels: [String] = []) {
        self.tempId = tempId; self.title = title; self.type = type; self.priority = priority
        self.description = description; self.acceptance = acceptance; self.labels = labels
    }
}

public enum ChangeOp: Equatable, Sendable {
    case createBead(NewBead)
    case addEdge(from: BeadRef, to: BeadRef, kind: EdgeKind)
    case editBead(id: String, set: FieldSet, pre: Precondition, delivery: Delivery?)
    case reopen(id: String, reason: String, pre: Precondition)
    case followUp(tempId: String, of: String, title: String, description: String, pre: Precondition)

    /// The existing bead this op writes to, if any — what drift and release recheck.
    public var existingTarget: String? {
        switch self {
        case .createBead: nil
        case .addEdge(let from, _, _): if case .existing(let id) = from { id } else { nil }
        case .editBead(let id, _, _, _), .reopen(let id, _, _): id
        case .followUp(_, let of, _, _, _): of
        }
    }
}

extension ChangeOp: Codable {
    private enum Key: String, CodingKey {
        case op, tempId, title, type, priority, description, acceptance, labels
        case from, to, kind, id, set, pre, delivery, reason, of
    }
    public struct UnknownOp: Error, Equatable { public let op: String }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        let op = try c.decode(String.self, forKey: .op)
        switch op {
        case "createBead":
            self = .createBead(NewBead(
                tempId: try c.decode(String.self, forKey: .tempId),
                title: try c.decode(String.self, forKey: .title),
                type: try c.decodeIfPresent(String.self, forKey: .type) ?? "task",
                priority: try c.decodeIfPresent(Int.self, forKey: .priority) ?? 2,
                description: try c.decode(String.self, forKey: .description),
                acceptance: try c.decodeIfPresent(String.self, forKey: .acceptance),
                labels: try c.decodeIfPresent([String].self, forKey: .labels) ?? []))
        case "addEdge":
            self = .addEdge(from: try c.decode(BeadRef.self, forKey: .from),
                            to: try c.decode(BeadRef.self, forKey: .to),
                            kind: try c.decodeIfPresent(EdgeKind.self, forKey: .kind) ?? .blocks)
        case "editBead":
            self = .editBead(id: try c.decode(String.self, forKey: .id),
                             set: try c.decode(FieldSet.self, forKey: .set),
                             pre: try c.decode(Precondition.self, forKey: .pre),
                             delivery: try c.decodeIfPresent(Delivery.self, forKey: .delivery))
        case "reopen":
            self = .reopen(id: try c.decode(String.self, forKey: .id),
                           reason: try c.decode(String.self, forKey: .reason),
                           pre: try c.decode(Precondition.self, forKey: .pre))
        case "followUp":
            self = .followUp(tempId: try c.decode(String.self, forKey: .tempId),
                             of: try c.decode(String.self, forKey: .of),
                             title: try c.decode(String.self, forKey: .title),
                             description: try c.decode(String.self, forKey: .description),
                             pre: try c.decode(Precondition.self, forKey: .pre))
        default:
            throw UnknownOp(op: op)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        switch self {
        case .createBead(let b):
            try c.encode("createBead", forKey: .op)
            try c.encode(b.tempId, forKey: .tempId); try c.encode(b.title, forKey: .title)
            try c.encode(b.type, forKey: .type); try c.encode(b.priority, forKey: .priority)
            try c.encode(b.description, forKey: .description)
            try c.encodeIfPresent(b.acceptance, forKey: .acceptance); try c.encode(b.labels, forKey: .labels)
        case .addEdge(let from, let to, let kind):
            try c.encode("addEdge", forKey: .op)
            try c.encode(from, forKey: .from); try c.encode(to, forKey: .to); try c.encode(kind, forKey: .kind)
        case .editBead(let id, let set, let pre, let delivery):
            try c.encode("editBead", forKey: .op)
            try c.encode(id, forKey: .id); try c.encode(set, forKey: .set); try c.encode(pre, forKey: .pre)
            try c.encodeIfPresent(delivery, forKey: .delivery)
        case .reopen(let id, let reason, let pre):
            try c.encode("reopen", forKey: .op)
            try c.encode(id, forKey: .id); try c.encode(reason, forKey: .reason); try c.encode(pre, forKey: .pre)
        case .followUp(let tempId, let of, let title, let description, let pre):
            try c.encode("followUp", forKey: .op)
            try c.encode(tempId, forKey: .tempId); try c.encode(of, forKey: .of)
            try c.encode(title, forKey: .title); try c.encode(description, forKey: .description)
            try c.encode(pre, forKey: .pre)
        }
    }
}

public struct ChangeSet: Codable, Equatable, Sendable {
    public var graphObservedAt: Date
    public var ops: [ChangeOp]
    public init(graphObservedAt: Date, ops: [ChangeOp]) { self.graphObservedAt = graphObservedAt; self.ops = ops }

    public static func decode(_ data: Data) throws -> ChangeSet { try IntakeJSON.decoder.decode(ChangeSet.self, from: data) }
    public func encoded() throws -> Data { try IntakeJSON.encoder.encode(self) }
}

public enum IntakeJSON {
    public static let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()
    public static let encoder: JSONEncoder = {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.prettyPrinted, .sortedKeys]; return e
    }()
}
