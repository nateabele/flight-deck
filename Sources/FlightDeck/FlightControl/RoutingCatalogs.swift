import Foundation
import IntakeKit

/// Claude's routable models: the aliases `ClaudeFlagCatalog` offers for `--model`, `opus` first
/// because it is Flight Deck's default claude model everywhere else (`AvailableModels.defaults`).
///
/// Aliases only. Claude has no model-list command, and a hand-kept list of full ids goes stale
/// silently — the failure a rule validated against it would then hide.
enum ClaudeRoutingCatalog {
    static var knobSchema: [String: [String]] { ["effort": choices("--effort")] }

    static var models: [ModelEntry] {
        let aliases = choices("--model")
        let ordered = aliases.filter { $0 == "opus" } + aliases.filter { $0 != "opus" }
        return ordered.map { ModelEntry(id: $0, displayName: $0.capitalized, knobs: ["effort"]) }
    }

    private static func choices(_ flag: String) -> [String] {
        guard let spec = ClaudeFlagCatalog.all.first(where: { $0.canonical == flag }),
              case .choice(let values, _) = spec.kind else { return [] }
        return values
    }
}

/// Codex's routable models, from the app-server's own `model/list` — the list codex itself
/// offers, so a model it retires leaves routing the same day.
///
/// A short-lived app-server rather than a session's per-account one: the list does not depend on
/// the account, and routing must work with no codex tab open. Cached for the launch, because
/// every compile and every release asks, and each ask would otherwise spawn a process. A failed
/// fetch is not cached: the next ask tries again.
@MainActor
final class CodexRoutingCatalog {
    static let shared = CodexRoutingCatalog()
    typealias Fetch = @MainActor () async throws -> [String: Any]

    private let fetch: Fetch
    private var cached: [ModelEntry]?
    /// The union of every listed model's efforts. Empty until a fetch succeeds, so a knob can
    /// never validate against a schema nobody has read.
    private(set) var knobSchema: [String: [String]] = [:]

    init(fetch: @escaping Fetch = CodexRoutingCatalog.liveFetch) { self.fetch = fetch }

    func models() async -> RoutingCapability<[ModelEntry]> {
        if let cached { return .supported(cached) }
        do {
            let (models, schema) = Self.parse(try await fetch())
            guard !models.isEmpty else { return .unsupported(reason: "codex listed no models") }
            cached = models
            knobSchema = schema
            return .supported(models)
        } catch {
            return .unsupported(reason: "codex model list unavailable: \(error)")
        }
    }

    func invalidate() {
        cached = nil
        knobSchema = [:]
    }

    /// Hidden models are left out; the `isDefault` model goes first, because
    /// `RoutingCapabilityRegistry.catalogs` takes the first model as the adapter's default.
    nonisolated static func parse(_ result: [String: Any]) -> ([ModelEntry], [String: [String]]) {
        var models: [ModelEntry] = []
        var efforts: [String] = []
        var defaultIndex: Int?
        for m in result["data"] as? [[String: Any]] ?? [] where (m["hidden"] as? Bool) != true {
            guard let id = m["id"] as? String, !id.isEmpty else { continue }
            let supported = (m["supportedReasoningEfforts"] as? [[String: Any]] ?? []).compactMap { $0["reasoningEffort"] as? String }
            for e in supported where !efforts.contains(e) { efforts.append(e) }
            if m["isDefault"] as? Bool == true, defaultIndex == nil { defaultIndex = models.count }
            models.append(ModelEntry(id: id, displayName: m["displayName"] as? String ?? id,
                                     knobs: supported.isEmpty ? [] : ["effort"]))
        }
        if let i = defaultIndex, i > 0 { models.insert(models.remove(at: i), at: 0) }
        return (models, efforts.isEmpty ? [:] : ["effort": efforts])
    }

    /// One app-server, handshake, every page of `model/list`, stop. Each page is raced against a
    /// timer: a wedged app-server must fail the compile, not hang the Settings pane forever.
    static func liveFetch() async throws -> [String: Any] {
        let transport = CodexProcessTransport()
        let rpc = CodexRPC(transport: transport)
        transport.onTerminate = { [weak rpc] in rpc?.transportClosed() }
        try transport.start()
        defer { transport.stop() }
        try await CodexProcessTransport.verifyHandshake(rpc)
        var all: [[String: Any]] = []
        var cursor: String?
        for _ in 0..<20 {
            let after = cursor
            let page: [String: Any] = try await withThrowingTaskGroup(of: [String: Any]?.self) { group in
                group.addTask {
                    var params: [String: Any] = ["includeHidden": false]
                    if let after { params["cursor"] = after }
                    return try await rpc.request("model/list", params)
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: 10_000_000_000)
                    throw CodexRPCError.timeout
                }
                defer { group.cancelAll() }
                return (try await group.next() ?? nil) ?? [:]
            }
            all += page["data"] as? [[String: Any]] ?? []
            cursor = page["nextCursor"] as? String
            if cursor == nil { break }
        }
        return ["data": all]
    }
}
