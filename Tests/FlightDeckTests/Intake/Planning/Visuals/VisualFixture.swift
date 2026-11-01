import CryptoKit
import Foundation
import IntakeKit

/// An intake folder with visuals in it, laid out as ThreadRunner will write them (spec §7):
/// `visuals/<id>/r<n>/manifest.json`, the files it lists, and `visuals/<id>/block.json`.
/// Only tests write `visuals/` in P2a.
struct VisualFixture {
    let root: URL
    var tape: TapeStore { TapeStore(intakeDirectory: root) }
    var store: DiskVisualStore { DiskVisualStore(intakeDirectory: root) }

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("VisualFixture-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    static let sequence = """
    sequenceDiagram
        participant Phone
        participant Mac as Mac · Flight Deck
        participant hostd
        Phone->>Mac: SPAKE2 message A (code typed or scanned)
        Mac-->>Phone: SPAKE2 message B
        Mac->>hostd: register controller key
        hostd-->>Mac: ok · controllers.json (0600)
        Mac-->>Phone: session token → Keychain
    """

    static let flowchart = """
    flowchart LR
        code[pairing code] --> spake[SPAKE2 exchange]
        spake --> key[controller key]
        spake --> token[session token]
        key --> store[(controllers.json)]
        token --> keychain[(Keychain)]
    """

    /// Not Mermaid: the arrow has no target.
    static let broken = """
    flowchart LR
        A[Phone] -->
        B[Mac
    """

    /// Revision `r` of `id`, drawn by Mermaid from `source`. `extra` files are written and listed;
    /// `unlisted` files are written and not listed.
    @discardableResult
    func revision(_ id: String, r: Int, source: String, kind: String = "sequence", title: String = "Pairing handshake",
                  states: [String] = [], sizes: [String] = [], primary: Bool = true, alternates: [VisualAlternate] = [],
                  madeBy: VisualMaker = .you, extra: [String: Data] = [:], unlisted: [String: Data] = [:]) throws -> URL {
        let vid = VisualID(rawValue: id)!
        let dir = tape.revisionDirectory(vid, r: r)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var files: [VisualFileEntry] = []
        func put(_ name: String, _ data: Data, listed: Bool) throws {
            let url = dir.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
            if listed { files.append(VisualFileEntry(path: name, size: Int64(data.count), sha256: Self.sha(data))) }
        }
        try put("diagram.mmd", Data(source.utf8), listed: true)
        for (name, data) in extra.sorted(by: { $0.key < $1.key }) { try put(name, data, listed: true) }
        for (name, data) in unlisted.sorted(by: { $0.key < $1.key }) { try put(name, data, listed: false) }
        let manifest = VisualManifest(provider: "fd.diagram.mermaid", providerVersion: "12.2.0", kind: kind, title: title,
                                      entry: "diagram.mmd", states: states, sizes: sizes, pins: .node, madeOnCheckpoint: 1,
                                      madeBy: madeBy, alternates: alternates, primary: primary, files: files)
        try IntakeJSON.encoder.encode(manifest).write(to: dir.appendingPathComponent("manifest.json"))
        return dir
    }

    func block(_ id: String, representations: [Int], primary: Int) throws {
        let vid = VisualID(rawValue: id)!
        let state = BlockState(representations: representations.map { RevisionRef(visualID: vid, r: $0) },
                               primary: RevisionRef(visualID: vid, r: primary))
        try FileManager.default.createDirectory(at: tape.visualsDirectory(vid), withIntermediateDirectories: true)
        try IntakeJSON.encoder.encode(state).write(to: tape.visualsDirectory(vid).appendingPathComponent("block.json"))
    }

    /// The pairing handshake with three representations: Sequence ★, Components (a flowchart a
    /// round proposed) and Data flow.
    func pairing() throws {
        try revision("pairing-handshake", r: 1, source: Self.sequence, kind: "sequence",
                     alternates: [VisualAlternate(revision: 2, kind: "component", reason: "Shows which module owns each step", by: .round("Refine 2")),
                                  VisualAlternate(revision: 3, kind: "flow", by: .you)])
        try revision("pairing-handshake", r: 2, source: Self.flowchart, kind: "component", primary: false, madeBy: .round("Refine 2"))
        try revision("pairing-handshake", r: 3, source: Self.flowchart.replacingOccurrences(of: "LR", with: "TD"), kind: "flow", primary: false)
        try block("pairing-handshake", representations: [1, 2, 3], primary: 1)
    }

    static func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    /// Where a test's PNGs go: `FD_PLANNING_RENDER_DIR` (or `FD_INTAKE_RENDER_DIR`) when set, which
    /// test-unit-remote.sh copies back; nil otherwise.
    static var renderDirectory: URL? {
        let env = ProcessInfo.processInfo.environment
        guard let dir = env["FD_PLANNING_RENDER_DIR"] ?? env["FD_INTAKE_RENDER_DIR"] else { return nil }
        let url = URL(fileURLWithPath: dir, isDirectory: true).appendingPathComponent("visuals", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
