import Foundation

public enum ExecutionBlockError: Error, Equatable, Sendable {
    case notJSONObject
    case missingField(String)
    case invalidField(String, String)
    case unsupportedVersion(Int)

    /// The one-line reason shown as "unroutable: <message>".
    public var message: String {
        switch self {
        case .notJSONObject: "agent_context is not a JSON object"
        case .missingField(let f): "missing \(f)"
        case .invalidField(let f, let why): "\(f): \(why)"
        case .unsupportedVersion(let v): "written by a newer Flight Deck (v\(v))"
        }
    }
}

/// Reads and writes the execution block inside br's `agent_context` JSON.
///
/// Hand-rolled over `JSONSerialization` rather than `Codable` so a bad block names the exact
/// field that is wrong, and so writing merges into whatever else `agent_context` holds instead
/// of replacing it — br's governing instructions live in the same field.
public enum ExecutionBlockCodec {
    private static func iso() -> ISO8601DateFormatter {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f
    }

    public static func decode(agentContext: String?) -> Result<ExecutionBlock?, ExecutionBlockError> {
        guard let text = agentContext, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .success(nil)
        }
        guard let root = (try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])) as? [String: Any] else {
            return .failure(.notJSONObject)
        }
        guard let fd = root["flight_deck"] as? [String: Any], let raw = fd["execution"] else { return .success(nil) }
        guard let e = raw as? [String: Any] else { return .failure(.invalidField("execution", "not an object")) }

        guard let v = e["v"] as? Int else { return .failure(.missingField("v")) }
        if v > ExecutionBlock.currentVersion { return .failure(.unsupportedVersion(v)) }

        func string(_ key: String) -> Result<String, ExecutionBlockError> {
            guard let value = e[key] else { return .failure(.missingField(key)) }
            guard let s = value as? String else { return .failure(.invalidField(key, "not a string")) }
            return s.isEmpty ? .failure(.invalidField(key, "empty")) : .success(s)
        }
        let kind: String, harness: String, model: String, pool: String
        switch string("kind") { case .success(let s): kind = s; case .failure(let x): return .failure(x) }
        switch string("harness") { case .success(let s): harness = s; case .failure(let x): return .failure(x) }
        switch string("model") { case .success(let s): model = s; case .failure(let x): return .failure(x) }
        switch string("pool") { case .success(let s): pool = s; case .failure(let x): return .failure(x) }

        var knobs: [String: String] = [:]
        if let rawKnobs = e["knobs"], !(rawKnobs is NSNull) {
            guard let dict = rawKnobs as? [String: Any] else { return .failure(.invalidField("knobs", "not an object")) }
            for (k, value) in dict {
                guard let s = value as? String else { return .failure(.invalidField("knobs", "values must be strings")) }
                knobs[k] = s
            }
        }

        guard let s = e["source"] else { return .failure(.missingField("source")) }
        guard let src = s as? [String: Any] else { return .failure(.invalidField("source", "not an object")) }
        guard let byRaw = src["by"] as? String else { return .failure(.missingField("source.by")) }
        guard let by = AssignmentSourceKind(rawValue: byRaw) else {
            return .failure(.invalidField("source.by", "unknown value \(byRaw)"))
        }
        guard let reason = src["reason"] as? String else { return .failure(.missingField("source.reason")) }
        guard let atRaw = src["at"] as? String else { return .failure(.missingField("source.at")) }
        guard let at = iso().date(from: atRaw) else { return .failure(.invalidField("source.at", "not ISO 8601")) }
        let ruleId = src["ruleId"] as? String

        let pinned: Bool
        if let p = e["pinned"], !(p is NSNull) {
            guard let b = p as? Bool else { return .failure(.invalidField("pinned", "not a boolean")) }
            pinned = b
        } else { pinned = false }
        let host = e["host"] as? String

        return .success(ExecutionBlock(v: v, kind: KindID(kind), harness: HarnessID(harness), model: model,
                                       knobs: knobs, pool: PoolID(pool),
                                       source: AssignmentSource(by: by, ruleId: ruleId, reason: reason, at: at),
                                       pinned: pinned, host: host))
    }

    /// The block as a JSON-ready dictionary — exposed so `br --agent-context` callers and
    /// fixtures build the exact same shape.
    public static func dictionary(_ b: ExecutionBlock) -> [String: Any] {
        var source: [String: Any] = ["by": b.source.by.rawValue, "reason": b.source.reason,
                                     "at": iso().string(from: b.source.at)]
        if let r = b.source.ruleId { source["ruleId"] = r }
        return ["v": b.v, "kind": b.kind.rawValue, "harness": b.harness.rawValue, "model": b.model,
                "knobs": b.knobs, "pool": b.pool.rawValue, "source": source, "pinned": b.pinned,
                "host": b.host as Any? ?? NSNull()]
    }

    /// Writes `block` into `agentContext`, keeping every other key. Throws `.notJSONObject`
    /// rather than overwrite a context that is not a JSON object — another tool owns it.
    public static func encode(_ block: ExecutionBlock, into agentContext: String?) throws -> String {
        var root: [String: Any] = [:]
        if let text = agentContext, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let obj = (try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])) as? [String: Any] else {
                throw ExecutionBlockError.notJSONObject
            }
            root = obj
        }
        var fd = root["flight_deck"] as? [String: Any] ?? [:]
        fd["execution"] = dictionary(block)
        root["flight_deck"] = fd
        let data = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
}
