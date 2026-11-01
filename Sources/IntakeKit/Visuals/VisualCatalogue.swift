import Foundation

/// One visual as a round sees it (spec §11, §12): what it is, where in the plan, and the files an
/// agent can open. Paths are absolute, inside the intake's `visuals/` folder.
public struct VisualCatalogueEntry: Equatable, Sendable {
    public var id: String
    public var kind: String
    public var title: String
    public var caption: String?
    /// The heading line the block sits under.
    public var section: String?
    /// The states a task can be built to match; the first is the default.
    public var states: [String]
    public var primaryRevision: Int
    /// The primary's entry file (`diagram.mmd`).
    public var sourcePath: String
    /// The primary's default snapshot, nil when the revision has none.
    public var snapshotPath: String?
    public init(id: String, kind: String, title: String, caption: String?, section: String?, states: [String],
                primaryRevision: Int, sourcePath: String, snapshotPath: String?) {
        self.id = id; self.kind = kind; self.title = title; self.caption = caption; self.section = section
        self.states = states; self.primaryRevision = primaryRevision
        self.sourcePath = sourcePath; self.snapshotPath = snapshotPath
    }
}

public enum VisualCatalogue {
    /// The plan's visuals that a task may cite, in plan order, each once: exactly the ids
    /// `PlanVisualFence.knownVisuals` accepts. The primary is the one the block state names
    /// (checkpoint `checkpoint`'s record first, as the plan shown, then the current one), else the
    /// newest revision.
    public static func entries(plan: String, store: any VisualStoreReading, tape: TapeStore,
                               checkpoint: Int? = nil) -> [VisualCatalogueEntry] {
        var seen = Set<VisualID>()
        var out: [VisualCatalogueEntry] = []
        for block in PlanVisualFence.blocks(in: plan) where !block.pending && seen.insert(block.id).inserted {
            let state = checkpoint.flatMap { store.blockState(block.id, checkpoint: $0) } ?? store.blockState(block.id)
            guard let r = state?.primary.r ?? store.revisions(block.id).last,
                  let rev = store.revision(block.id, r: r) else { continue }
            let m = rev.manifest
            let dir = tape.revisionDirectory(block.id, r: r)
            out.append(VisualCatalogueEntry(
                id: block.id.rawValue, kind: m.kind, title: m.title, caption: block.caption, section: block.section,
                states: m.states.isEmpty ? ["default"] : m.states, primaryRevision: r,
                sourcePath: dir.appendingPathComponent(m.entry).path,
                snapshotPath: PlanExporter.defaultSnapshot(m).map { dir.appendingPathComponent($0).path }))
        }
        return out
    }
}
