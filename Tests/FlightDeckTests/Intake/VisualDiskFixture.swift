import Foundation
import CryptoKit
import IntakeKit

/// Writes a visual revision and its `block.json` the way ThreadRunner will, for tests only.
enum VisualDiskFixture {
    /// `visuals/<id>/r<r>/` with each file and a manifest listing it (true sizes and hashes), plus
    /// `block.json` naming `r` primary unless `blockState` is false.
    @discardableResult
    static func install(_ tape: TapeStore, id raw: String, r: Int = 1, kind: String = "sequence", title: String = "Pairing",
                        states: [String] = ["default"], sizes: [String] = ["wide"],
                        files: [String: Data]? = nil, blockState: Bool = true) throws -> VisualID {
        let id = VisualID(rawValue: raw)!
        let dir = tape.revisionDirectory(id, r: r)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let contents = files ?? ["diagram.mmd": Data("sequenceDiagram\n  A->>B: hi\n".utf8),
                                 "snapshot@\(states[0])-\(sizes[0]).png": png(width: 800, height: 400)]
        var entries: [VisualFileEntry] = []
        for (path, data) in contents.sorted(by: { $0.key < $1.key }) {
            let url = dir.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
            entries.append(VisualFileEntry(path: path, size: Int64(data.count),
                                           sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()))
        }
        let manifest = VisualManifest(provider: "mermaid", providerVersion: "12.2.0", kind: kind, title: title,
                                      entry: "diagram.mmd", states: states, sizes: sizes, madeOnCheckpoint: 1,
                                      madeBy: .you, primary: true, files: entries)
        try IntakeJSON.encoder.encode(manifest).write(to: dir.appendingPathComponent("manifest.json"))
        if blockState {
            let ref = RevisionRef(visualID: id, r: r)
            try IntakeJSON.encoder.encode(BlockState(representations: [ref], primary: ref))
                .write(to: tape.visualsDirectory(id).appendingPathComponent("block.json"))
        }
        return id
    }

    /// The first 24 bytes of a PNG (signature and IHDR), which is all a size reader looks at.
    static func png(width: UInt32, height: UInt32) -> Data {
        var d = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13, 0x49, 0x48, 0x44, 0x52])
        for v in [width, height] { withUnsafeBytes(of: v.bigEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: [8, 6, 0, 0, 0, 0, 0, 0, 0])
        return d
    }
}
