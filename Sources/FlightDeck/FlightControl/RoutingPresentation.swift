import Foundation
import IntakeKit

/// What one rule row shows and which buttons it enables.
struct RuleRowPresentation: Equatable {
    var stateLabel: String
    var compiledText: String?
    var failureText: String?
    var note: String?
    var canCompile: Bool
    var canConfirm: Bool

    /// A confirmed rule offers no Compile: recompiling the same words could silently change what
    /// routes. Editing the sentence is the way back to draft (spec §2).
    ///
    /// `hasUncommittedEdit` is a typed-but-not-submitted sentence. Until it is committed the rule
    /// still holds the OLD compiled form, so Confirm would confirm that form under words it was
    /// not compiled from: Confirm is off, and Compile is on in any state (the row commits the edit
    /// first, which sends the rule back to draft, then compiles the new sentence).
    init(rule: RoutingRule, compiling: Bool, note: String?, hasUncommittedEdit: Bool = false) {
        if compiling {
            stateLabel = "Compiling…"
        } else {
            switch rule.state {
            case .draft: stateLabel = "Draft"
            case .compiled: stateLabel = "Compiled — confirm to use"
            case .confirmed: stateLabel = "Confirmed"
            case .failed: stateLabel = "Failed"
            }
        }
        compiledText = rule.compiled.map(RuleText.compiled)
        failureText = rule.state == .failed ? rule.failure.map { "Failed: \($0)" } : nil
        self.note = note
        canCompile = !compiling && (hasUncommittedEdit || rule.state == .draft || rule.state == .failed)
        canConfirm = !compiling && !hasUncommittedEdit && rule.state == .compiled
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
