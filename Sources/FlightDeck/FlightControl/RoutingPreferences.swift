import Foundation
import IntakeKit

/// The global half of routing state. Project rules are not here: they live in the project's
/// own `.flightdeck/routing.json` so they travel with the repo.
struct RoutingPreferences: Codable, Equatable {
    var globalRules: [RoutingRule]
    var compiler: RuleCompilerSettings?
    /// Standardized project path → kind ids you have opened. Per-user, so not in `kinds.json`.
    var seenKinds: [String: [String]]?
    /// Rule id → the index snapshot date whose hint you dismissed (spec §7).
    var dismissedHints: [String: Date]?

    init(globalRules: [RoutingRule] = [], compiler: RuleCompilerSettings? = nil,
         seenKinds: [String: [String]]? = nil, dismissedHints: [String: Date]? = nil) {
        self.globalRules = globalRules; self.compiler = compiler
        self.seenKinds = seenKinds; self.dismissedHints = dismissedHints
    }
}

extension PreferencesStore {
    /// Must match the spelling of `PreferencesStore.key` (private there, so duplicated here): a
    /// different spelling would split one project's seen kinds across two entries, so `/p/` and `/p`
    /// would each re-announce every kind as new.
    private static func routingKey(_ path: String) -> String {
        URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path
    }

    private var routing: RoutingPreferences { preferences.flightControlRouting ?? RoutingPreferences() }

    /// Writes only on a real change: `preferences`' didSet persists every assignment, and the
    /// Task kinds pane marks kinds seen from view callbacks.
    private func mutateRouting(_ body: (inout RoutingPreferences) -> Void) {
        var next = routing
        body(&next)
        guard next != routing else { return }
        preferences.flightControlRouting = next
    }

    var globalRoutingRules: [RoutingRule] {
        get { routing.globalRules }
        set { mutateRouting { $0.globalRules = newValue } }
    }

    var routingCompilerSettings: RuleCompilerSettings {
        get { routing.compiler ?? .default }
        set { mutateRouting { $0.compiler = newValue } }
    }

    func seenKinds(project: String) -> Set<KindID> {
        Set((routing.seenKinds?[Self.routingKey(project)] ?? []).map(KindID.init(rawValue:)))
    }

    func markKindsSeen(_ ids: [KindID], project: String) {
        let key = Self.routingKey(project)
        let seen = seenKinds(project: project)
        let fresh = ids.filter { !seen.contains($0) }
        guard !fresh.isEmpty else { return }
        mutateRouting { r in
            var map = r.seenKinds ?? [:]
            map[key, default: []] += fresh.map(\.rawValue)
            r.seenKinds = map
        }
    }

    func isHintDismissed(ruleID: String, snapshot: Date) -> Bool {
        routing.dismissedHints?[ruleID] == snapshot
    }

    func dismissHint(ruleID: String, snapshot: Date) {
        mutateRouting { r in
            var map = r.dismissedHints ?? [:]
            map[ruleID] = snapshot
            r.dismissedHints = map
        }
    }
}
