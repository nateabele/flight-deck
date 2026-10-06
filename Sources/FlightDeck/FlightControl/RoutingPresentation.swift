import Foundation
import IntakeKit

/// What one rule row shows (spec L3-R §2): the sentence on line 1; on line 2 either the
/// compiled form as pills or one line of text (a failure or a draft's note); and exactly one
/// trailing status. Decided here, outside SwiftUI, so it is unit-tested; the view only lays it out.
struct RuleRowPresentation: Equatable {
    /// The one trailing status a row shows.
    enum Status: Equatable {
        /// Confirmed: a green check.
        case live
        /// Compiled, not confirmed: the Use button. Only confirmed rules route.
        case awaitingUse
        /// A red warning; the reason is line 2.
        case failed
        /// A small spinner.
        case compiling
        /// Never compiled, or the compiler could not run; line 2 says how to retry.
        case draft
    }

    struct Condition: Equatable {
        var index: Int
        var text: String
        var accessibilityLabel: String
    }

    var status: Status
    var conditions: [Condition]
    /// Between condition pills: "or" for an `any` match, "and" for `all`. Spelled out because
    /// the two route very differently and pills alone look the same either way.
    var joiner: String
    var target: String?
    var targetAccessibility: String?
    /// Line 2 when there are no pills.
    var detail: String?
    var adjusted: Bool
    var statusAccessibility: String
    /// The whole compiled form in plain words, on hover.
    var tooltip: String?
    var canUse: Bool
    /// Pills open popovers only on a compiled or live rule that is not mid-compile.
    var canAdjust: Bool

    init(rule: RoutingRule, compiling: Bool, note: String?, catalogs: AdapterCatalogs,
         defaultPools: [HarnessID: PoolID]) {
        if compiling {
            status = .compiling
        } else {
            switch rule.state {
            case .confirmed: status = .live
            case .compiled: status = .awaitingUse
            case .failed: status = .failed
            case .draft: status = .draft
            }
        }
        // Mid-compile the old pills are about to be replaced, so line 2 is the spinner alone.
        let showsPills = status == .live || status == .awaitingUse
        let compiled = showsPills ? rule.compiled : nil

        conditions = (compiled?.match.terms ?? []).enumerated().map { i, term in
            switch term {
            case .dimension(let d, let atLeast):
                return Condition(index: i, text: "\(d) ≥ \(RuleText.number(atLeast))",
                                 accessibilityLabel: "Condition: \(d) at least \(RuleText.number(atLeast))")
            case .kind(let k):
                return Condition(index: i, text: "kind: \(k.rawValue)", accessibilityLabel: "Condition: kind \(k.rawValue)")
            }
        }
        if case .all = compiled?.match { joiner = "and" } else { joiner = "or" }
        target = compiled.map { Self.targetText($0.assign, catalogs: catalogs, defaultPools: defaultPools) }
        targetAccessibility = target.map { "Routes to \($0)" }
        tooltip = compiled.map(RuleText.compiled)

        switch status {
        case .failed: detail = rule.failure ?? "The compiler could not read this rule — reword it"
        case .draft: detail = note.map { "\($0) — press Return to try again" } ?? "Not compiled — press Return to compile"
        case .compiling: detail = "Compiling…"
        case .live, .awaitingUse: detail = nil
        }
        adjusted = rule.adjusted && compiled != nil

        switch status {
        case .live: statusAccessibility = "Live"
        case .awaitingUse: statusAccessibility = "Compiled — not routing yet. Use"
        case .failed: statusAccessibility = "Failed: \(detail ?? "")"
        case .compiling: statusAccessibility = "Compiling"
        case .draft: statusAccessibility = "Not compiled: \(detail ?? "")"
        }
        canUse = status == .awaitingUse
        canAdjust = (status == .live || status == .awaitingUse) && compiled != nil
    }

    /// "Codex · GPT-6-Sol · high". The pool is named only when it is not the agent's default,
    /// the same way a default goes unsaid anywhere else in Settings.
    static func targetText(_ a: RuleAssign, catalogs: AdapterCatalogs, defaultPools: [HarnessID: PoolID]) -> String {
        var parts = [agentName(a.harness)]
        parts.append(catalogs.byHarness[a.harness]?.models.first { $0.id == a.model }?.displayName ?? a.model)
        parts += a.knobs.sorted { $0.key < $1.key }.map(\.value)
        var text = parts.joined(separator: " · ")
        let poolIsDefault = defaultPools[a.harness] == a.pool
        if !poolIsDefault { text += " · \(a.pool.rawValue)" }
        if let fallback = a.fallbackPool { text += poolIsDefault ? " · else \(fallback.rawValue)" : ", else \(fallback.rawValue)" }
        return text
    }

    static func agentName(_ h: HarnessID) -> String {
        AgentID.allCases.first { $0.harnessID == h }?.displayName ?? h.rawValue.prefix(1).uppercased() + h.rawValue.dropFirst()
    }
}

/// What one kind row shows (spec §6).
struct KindRowPresentation: Equatable {
    struct Bar: Equatable {
        var dimension: String
        var weight: Double
    }

    var id: String
    var name: String
    var originLabel: String
    var statusLabel: String
    var isNew: Bool
    var openCount: Int
    var bars: [Bar]

    init(kind: TaskKind, isNew: Bool, openCount: Int) {
        id = kind.id.rawValue
        name = kind.name
        switch kind.origin {
        case .seed: originLabel = "Seed"
        case .planning: originLabel = "Planning"
        case .user: originLabel = "You"
        }
        switch kind.status {
        case .active: statusLabel = "Active"
        case .proposed: statusLabel = "Proposed"
        case .merged(let target): statusLabel = "Merged into \(target.rawValue)"
        }
        self.isNew = isNew
        self.openCount = openCount
        // Every dimension, in catalog order, so two rows' bars line up and compare by eye.
        bars = Dimensions.all.map { Bar(dimension: $0.id, weight: kind.dimensions[$0.id] ?? 0) }
    }

    /// Live kinds other than this one. Not a merged kind: merging into one would build a chain
    /// (the registry refuses it anyway); not itself, which is meaningless. Uses `isLive` (R9).
    static func mergeTargets(for kind: TaskKind, in kinds: [TaskKind]) -> [TaskKind] {
        kinds.filter { $0.id != kind.id && $0.isLive }
    }
}
