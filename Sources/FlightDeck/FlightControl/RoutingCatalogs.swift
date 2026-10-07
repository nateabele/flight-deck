import Foundation
import IntakeKit

/// Claude's routable models: the claude profile's aliases — the same list Settings offers for
/// `--model` and the Rounds editor suggests — with the profile's planning default (`opus`)
/// first, because `RoutingCapabilityRegistry.catalogs` takes the first model as the default.
///
/// Aliases only. Claude has no model-list command, and a hand-kept list of full ids goes stale
/// silently — the failure a rule validated against it would then hide.
enum ClaudeRoutingCatalog {
    static var knobSchema: [String: [String]] { ["effort": ClaudeProfile.catalog.effortValues] }

    static var models: [ModelEntry] {
        let catalog = ClaudeProfile.catalog
        let first = catalog.defaultPlanningModel
        let ordered = catalog.aliases.filter { $0 == first } + catalog.aliases.filter { $0 != first }
        return ordered.map { ModelEntry(id: $0, displayName: $0.capitalized, knobs: ["effort"]) }
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

    /// The ids of the last successful fetch, or none — a read that never fetches, for views
    /// that may only show what is already known (the Rounds editor's model menu).
    var cachedModelIDs: [String] { cached?.map(\.id) ?? [] }

    func invalidate() {
        cached = nil
        knobSchema = [:]
    }

    /// Hidden models are left out; the `isDefault` model goes first, because
    /// `RoutingCapabilityRegistry.catalogs` takes the first model as the adapter's default.
    /// The listing itself is `CodexProfile.listedModels` — the one reader of `model/list`, so
    /// routing and the profile's `parseModelList` can never disagree on which models exist.
    nonisolated static func parse(_ result: [String: Any]) -> ([ModelEntry], [String: [String]]) {
        var efforts: [String] = []
        let models = CodexProfile.listedModels(result).map { m -> ModelEntry in
            for e in m.efforts where !efforts.contains(e) { efforts.append(e) }
            return ModelEntry(id: m.id, displayName: m.displayName, knobs: m.efforts.isEmpty ? [] : ["effort"])
        }
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
