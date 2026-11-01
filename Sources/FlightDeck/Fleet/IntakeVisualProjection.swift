import FleetKit
import Foundation
import IntakeKit

/// A plan's visual blocks as the phone reads them (spec §10): one `WireVisualRef` per visual, in
/// plan order, so the reader lays each block out before its bytes arrive.
///
/// The block's representations come from `VisualBlockModel.load`, the same read the Mac's editor
/// makes, so both ends show the same primary and filmstrip for the same checkpoint.
enum IntakeVisualProjection {
    /// nil for a plan with no `fd-visual` block, so such a plan's wire is what it always was. A
    /// pending placeholder or a visual with nothing stored is left out: the phone shows it as
    /// waiting.
    static func refs(markdown: String, checkpoint: Int?, reader: any VisualStoreReading) -> [WireVisualRef]? {
        let blocks = PlanVisualFence.blocks(in: markdown)
        guard !blocks.isEmpty else { return nil }
        var seen = Set<VisualID>()
        var out: [WireVisualRef] = []
        for block in blocks where seen.insert(block.id).inserted {
            let model = VisualBlockModel.load(id: block.id.rawValue, pending: block.pending, store: reader, checkpoint: checkpoint)
            let reps = model.representations
            guard !reps.isEmpty else { continue }
            let primary = reps[model.primaryIndex]
            let m = primary.revision.manifest
            out.append(WireVisualRef(
                id: block.id.rawValue, revision: primary.revision.r,
                kinds: reps.map(\.revision.manifest.kind),
                alternates: reps.enumerated().filter { $0.offset != model.primaryIndex }.map { _, rep in
                    WireVisualAlternate(revision: rep.revision.r, kind: rep.revision.manifest.kind, reason: rep.reason,
                                        files: wireFiles(rep.revision.manifest))
                },
                states: m.states, sizes: m.sizes,
                aspect: PlanExporter.defaultSnapshot(m).flatMap { aspect(reader, block.id, r: primary.revision.r, png: $0) },
                files: wireFiles(m)))
        }
        return out
    }

    /// A revision's fetchable files as the wire lists them: an alternate's too, so the phone can open it.
    static func wireFiles(_ m: VisualManifest) -> [WireVisualFile] {
        m.files.map { WireVisualFile(path: $0.path, size: $0.size, sha256: $0.sha256) }
    }

    /// Width over height from a PNG's IHDR (bytes 16–23), read through the store like any other
    /// byte the phone gets. nil for anything that is not a PNG with a non-zero size.
    static func aspect(_ reader: any VisualStoreReading, _ id: VisualID, r: Int, png name: String) -> Double? {
        guard let head = reader.read(id, r: r, name: name, offset: 0, limit: 24)?.data, head.count == 24,
              head.prefix(8) == Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]),
              head[head.startIndex + 12..<head.startIndex + 16] == Data("IHDR".utf8) else { return nil }
        func be32(_ at: Int) -> UInt32 {
            head[head.startIndex + at..<head.startIndex + at + 4].reduce(0) { $0 << 8 | UInt32($1) }
        }
        let w = be32(16), h = be32(20)
        guard w > 0, h > 0 else { return nil }
        return Double(w) / Double(h)
    }
}
