import AppKit
import IntakeKit

/// What one `fd-visual` block shows, read from the intake's visuals (spec §7): its
/// representations in filmstrip order with the ★ primary, or why there is nothing to show.
///
/// Built from the store once per block per load, not per draw: the overlay asks for it on every
/// scroll tick, and a manifest read is a file open.
struct VisualBlockModel: Equatable {
    /// One way of showing the visual: a revision, and how the filmstrip labels it.
    struct Representation: Equatable {
        let revision: VisualRevision
        /// "Sequence", "Components": the chip and the thumbnail's label.
        let label: String
        let isPrimary: Bool
        /// A round proposed it and it is not the primary: the filmstrip outlines it in amber with
        /// its reason (spec §8).
        let proposedByRound: Bool
        let reason: String?
    }

    enum Content: Equatable {
        /// No loadable revision: the id has no folder, or nothing in it loads. A quiet placeholder
        /// of fixed height, never a crash and never a collapsed block (Review Focus 1).
        case missing
        /// Asked for (`pending` in the fence) and not made yet.
        case pending
        case ready([Representation])
    }

    let id: String
    let content: Content
    /// Width over height of the primary's stored default snapshot, when it has one.
    var aspect: Double? = nil

    var representations: [Representation] {
        if case .ready(let reps) = content { return reps }
        return []
    }

    var primaryIndex: Int { representations.firstIndex(where: \.isPrimary) ?? 0 }

    /// The block's title: the primary's manifest title.
    var title: String? {
        let reps = representations
        guard !reps.isEmpty else { return nil }
        let title = reps[primaryIndex].revision.manifest.title
        return title.isEmpty ? nil : title
    }

    /// Reads the block from `store`. `checkpoint` is the plan version shown: an older plan shows
    /// its visuals as that checkpoint recorded them (spec §7), and falls back to the current block
    /// state when it recorded none.
    static func load(id: String, pending: Bool, store: (any VisualStoreReading)?, checkpoint: Int? = nil) -> VisualBlockModel {
        guard let store, let vid = VisualID(rawValue: id) else { return VisualBlockModel(id: id, content: pending ? .pending : .missing) }
        let recorded = checkpoint.flatMap { store.blockState(vid, checkpoint: $0) }
        var refs: [Int]
        var primary: Int?
        if let state = recorded ?? store.blockState(vid) {
            refs = state.representations.filter { $0.visualID == vid }.map(\.r)
            primary = state.primary.r
            if let primary, !refs.contains(primary) { refs.insert(primary, at: 0) }
        } else {
            // No block state yet (a revision written before its block.json): every revision, the
            // one its manifest marks primary as ★, else the newest.
            refs = store.revisions(vid)
        }
        let revisions = refs.compactMap { store.revision(vid, r: $0) }
        guard !revisions.isEmpty else { return VisualBlockModel(id: id, content: pending ? .pending : .missing) }
        let star = primary.flatMap { p in revisions.firstIndex { $0.r == p } }
            ?? revisions.firstIndex { $0.manifest.primary } ?? revisions.count - 1
        // What the primary's manifest says about each alternate: the round that proposed it, and why.
        let alternates = Dictionary(revisions[star].manifest.alternates.map { ($0.revision, $0) }, uniquingKeysWith: { a, _ in a })
        let reps = revisions.enumerated().map { i, revision in
            let alternate = alternates[revision.r]
            let byRound = (alternate?.by ?? revision.manifest.madeBy).kind == "round"
            return Representation(revision: revision,
                                  label: VisualKindLabel.label(alternate?.kind ?? revision.manifest.kind),
                                  isPrimary: i == star, proposedByRound: i != star && byRound, reason: alternate?.reason)
        }
        // The stored default snapshot's shape, when there is one, sizes the body (B-M1).
        let starred = revisions[star]
        let aspect = PlanExporter.defaultSnapshot(starred.manifest)
            .flatMap { IntakeVisualProjection.aspect(store, vid, r: starred.r, png: $0) }
        return VisualBlockModel(id: id, content: .ready(reps), aspect: aspect)
    }
}

/// A kind as the chip shows it: "sequence" → "Sequence", "component" → "Components".
enum VisualKindLabel {
    static func label(_ kind: String) -> String {
        switch kind.lowercased() {
        case "sequence": "Sequence"
        case "component", "components": "Components"
        case "flow", "dataflow", "data-flow": "Data flow"
        case "flowchart": "Flowchart"
        case "state": "State"
        case "er": "Entity relations"
        case "mermaid", "diagram": "Diagram"
        case "": "Visual"
        default: kind.prefix(1).uppercased() + kind.dropFirst()
        }
    }
}

/// The block's fixed sizes. The styler holds the block's hidden source to `height(for:)`, so the
/// text below starts exactly where the view ends, and the height never depends on what the web
/// view draws: a diagram that loads late, fails to parse or is swapped for its snapshot changes
/// nothing around it.
enum VisualBlockLayout {
    static let header: CGFloat = 40
    static let body: CGFloat = 320
    static let filmstrip: CGFloat = 104
    /// The missing and pending placeholders: quiet, and the same height every time.
    static let placeholder: CGFloat = 76
    /// Room kept above and below the block, as paragraph spacing on its hidden lines.
    static let spaceBefore: CGFloat = 6
    static let spaceAfter: CGFloat = 14

    /// The body's bounds when it follows the drawing's shape (final review B-M1).
    static let minBody: CGFloat = 160
    static let maxBody: CGFloat = 640

    /// The block's height at body width `width`: the body follows the stored snapshot's shape, or
    /// with none the live drawing's (`renderedAspect`), clamped to 160–640 pt; with neither, `body`.
    static func height(for model: VisualBlockModel, width: CGFloat, renderedAspect: Double? = nil) -> CGFloat {
        guard case .ready(let reps) = model.content else { return placeholder }
        var bodyHeight = body
        if let aspect = model.aspect ?? renderedAspect, aspect > 0, aspect.isFinite, width > 0 {
            bodyHeight = min(max((width / aspect).rounded(), minBody), maxBody)
        }
        return header + bodyHeight + (reps.count > 1 ? filmstrip : 0)
    }

    static func height(for model: VisualBlockModel) -> CGFloat {
        switch model.content {
        case .missing, .pending: placeholder
        case .ready(let reps): header + body + (reps.count > 1 ? filmstrip : 0)
        }
    }
}
