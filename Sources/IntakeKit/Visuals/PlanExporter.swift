import Foundation
import CryptoKit

/// One file of a release export, with its path relative to `PlanExport.directory`.
public struct ExportedFile: Equatable, Sendable {
    public var path: String
    public var data: Data
    public init(path: String, data: Data) { self.path = path; self.data = data }
}

/// What the release confirmation sheet shows before anything is written (spec §12, "Confirmation").
public struct PlanExportPreview: Equatable, Sendable {
    /// Repo-relative, sorted.
    public var paths: [String]
    public var commitMessage: String
    /// Repo-relative files already committed there that this release deletes (the new export no
    /// longer has them), sorted.
    public var removed: [String]
    public init(paths: [String], commitMessage: String, removed: [String] = []) {
        self.paths = paths; self.commitMessage = commitMessage; self.removed = removed
    }
}

/// Everything release will put in the repo for one intake: `docs/plans/<slug>/`, as bytes, with
/// nothing yet written. `PlanExporter` decides it; `RepoCommitter` writes and commits it.
public struct PlanExport: Equatable, Sendable {
    public var slug: String
    public var files: [ExportedFile]
    /// Things the human should know that did not stop the export (a cited visual that is gone).
    public var warnings: [String]
    /// The ids of blocks with nothing stored to export, in plan order: the plan carries a note in
    /// their place. Release refuses such a plan, so no task cites a folder that is not written.
    public var missing: [String] = []
    public init(slug: String, files: [ExportedFile], warnings: [String], missing: [String] = []) {
        self.slug = slug; self.files = files; self.warnings = warnings; self.missing = missing
    }

    /// Repo-relative, with no trailing slash: also the one pathspec git is given.
    public var directory: String { "\(PlanExporter.plansRoot)/\(slug)" }
    public var commitMessage: String { "docs: plan \(slug) for release" }
    public func file(_ path: String) -> ExportedFile? { files.first { $0.path == path } }
    public var preview: PlanExportPreview {
        PlanExportPreview(paths: files.map { "\(directory)/\($0.path)" }.sorted(), commitMessage: commitMessage)
    }
}

/// Who a `docs/plans/<slug>/` folder belongs to, read from its marker file.
public enum SlugOwner: Equatable, Sendable {
    case free
    /// The folder exists and names the intake that wrote it.
    case intake(String)
    /// The folder exists with no marker: someone's own docs. Never taken over.
    case unmarked
}

/// Decides which files a release writes and where (spec §12). Pure: it reads visuals only through
/// `VisualStoreReading` and touches no disk, so the same inputs always give the same export.
public enum PlanExporter {
    public static let plansRoot = "docs/plans"
    /// The file in a slug folder that records the intake id. A re-release finds its own folder by
    /// it; without a marker a folder is never taken over, since it may hold someone's own docs.
    public static let markerName = ".flightdeck-intake"
    public static let alternatesReadme = "Not chosen. Do not implement from these.\n"
    /// The size of one `read` call. The store caps a file at 10 MB; a chunk keeps one read small.
    public static let chunkBytes = 1_048_576
    private static let alternatesDir = "_unused-alternates"

    public enum Failure: Error, Equatable {
        /// The store would not hand over a file its manifest lists.
        case unreadable(visual: String, path: String)
        /// A manifest path that is absolute, has `..`, or would land on a name the export owns.
        case unsafePath(String)
    }

    // MARK: Slug

    /// Lowercase ASCII letters and digits joined by single hyphens, at most 48 characters; "plan"
    /// when nothing usable is left. The title is agent- and human-written, so it never becomes a
    /// path component as it stands.
    public static func slug(for title: String) -> String {
        // Transliterated first, so a title in another script still names its folder.
        let latin = title.applyingTransform(.toLatin, reverse: false) ?? title
        let folded = (latin.applyingTransform(.stripDiacritics, reverse: false) ?? latin)
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        var out = ""
        var pendingHyphen = false
        for b in folded.lowercased().utf8 {
            let alnum = (b >= 97 && b <= 122) || (b >= 48 && b <= 57)
            if alnum {
                if pendingHyphen, !out.isEmpty { out.append("-") }
                pendingHyphen = false
                out.append(Character(UnicodeScalar(b)))
            } else {
                pendingHyphen = true
            }
        }
        if out.count > 48 { out = String(out.prefix(48)) }
        while out.hasSuffix("-") { out.removeLast() }
        if out.isEmpty { return "plan" }
        // Windows cannot create these names, and a checkout there would fail.
        return reservedNames.contains(out) ? out + "-x" : out
    }

    private static let reservedNames: Set<String> = Set(
        ["con", "prn", "aux", "nul"] + (1...9).flatMap { ["com\($0)", "lpt\($0)"] })

    /// The base slug, or `-2`, `-3`, … for the first folder that is free or this intake's own.
    public static func resolveSlug(title: String, intakeID: String, owner: (String) -> SlugOwner) -> String {
        let base = slug(for: title)
        var n = 1
        while true {
            let candidate = n == 1 ? base : "\(base)-\(n)"
            switch owner(candidate) {
            case .free: return candidate
            case .intake(let id) where id == intakeID: return candidate
            default: n += 1
            }
        }
    }

    // MARK: Export

    /// `blockStates` wins over the store's own `block.json`: a release exports the block states
    /// the plan checkpoint saw. A visual in neither is "missing", and the plan says so.
    public static func export(plan: String, slug: String, intakeID: String, store: VisualStoreReading,
                              blockStates: [VisualID: BlockState]) throws -> PlanExport {
        var warnings: [String] = []
        var visualFiles: [ExportedFile] = []
        var exported = Set<VisualID>()
        var decided: [VisualID: Rendered] = [:]
        var missing: [String] = []

        func render(_ id: VisualID) throws -> Rendered? {
            if let d = decided[id] { return d }
            guard let state = blockStates[id] ?? store.blockState(id),
                  let rev = store.revision(id, r: state.primary.r) else { return nil }
            let m = rev.manifest
            if !exported.contains(id) {
                exported.insert(id)
                visualFiles += try files(of: id, revision: rev, state: state, store: store)
            }
            let r = Rendered(title: m.title, snapshot: defaultSnapshot(m))
            decided[id] = r
            return r
        }

        var md: [String] = []
        let lines = plan.components(separatedBy: "\n")
        var i = 0
        while i < lines.count {
            let line = lines[i]
            guard let open = PlanVisualFence.fenceOpen(line) else { md.append(line); i += 1; continue }
            var j = i + 1
            while j < lines.count, !PlanVisualFence.isClose(lines[j], of: open) { j += 1 }
            let closed = j < lines.count
            let end = closed ? j : lines.count - 1
            if closed, let v = PlanVisualFence.parse(open.info), let id = VisualID(rawValue: v.id) {
                let caption = lines[(i + 1)..<j].map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
                if let r = try render(id) {
                    let text = escape(caption ?? (r.title.isEmpty ? id.rawValue : r.title))
                    if let snap = r.snapshot { md.append("![\(text)](visuals/\(id.rawValue)/\(snap))"); md.append("") }
                    md.append("[\(text): files](visuals/\(id.rawValue)/)")
                } else {
                    warnings.append("visual \(id.rawValue) has no stored revision, so the plan carries a note instead")
                    if !missing.contains(id.rawValue) { missing.append(id.rawValue) }
                    md.append("> Visual `\(id.rawValue)` was not available when this plan was released.")
                }
            } else {
                // Not a visual (or never closed): copied through whole, so a nested example stays text.
                md.append(contentsOf: lines[i...end])
            }
            i = end + 1
        }

        var all = [ExportedFile(path: "plan.md", data: Data(md.joined(separator: "\n").utf8)),
                   ExportedFile(path: markerName, data: Data((intakeID + "\n").utf8))]
        all += visualFiles
        return PlanExport(slug: slug, files: all, warnings: warnings, missing: missing)
    }

    // MARK: Pieces

    private struct Rendered { var title: String; var snapshot: String? }

    private static func files(of id: VisualID, revision rev: VisualRevision, state: BlockState,
                              store: VisualStoreReading) throws -> [ExportedFile] {
        let base = "visuals/\(id.rawValue)"
        var out: [ExportedFile] = []
        var seen = Set<String>()
        for entry in rev.manifest.files {
            guard isSafe(entry.path) else { throw Failure.unsafePath(entry.path) }
            guard seen.insert(entry.path).inserted else { continue }
            out.append(ExportedFile(path: "\(base)/\(entry.path)", data: try readAll(store, id, rev.r, entry.path, sha256: entry.sha256)))
        }
        let readmePath = "\(base)/README.md"
        if out.contains(where: { $0.path == readmePath }) { throw Failure.unsafePath("README.md") }
        out.append(ExportedFile(path: readmePath, data: Data(readme(id: id, manifest: rev.manifest).utf8)))
        // Alternates get a marker and nothing else: their bytes must not look implementable.
        let alts = Set(state.representations.map(\.r)).subtracting([state.primary.r]).sorted()
        for n in alts {
            out.append(ExportedFile(path: "\(base)/\(alternatesDir)/\(n)/README.md", data: Data(alternatesReadme.utf8)))
        }
        return out
    }

    private static func readAll(_ store: VisualStoreReading, _ id: VisualID, _ r: Int, _ name: String,
                                sha256: String) throws -> Data {
        var data = Data()
        var offset: Int64 = 0
        while true {
            guard let slice = store.read(id, r: r, name: name, offset: offset, limit: chunkBytes) else {
                throw Failure.unreadable(visual: id.rawValue, path: name)
            }
            // Empty before the end is a broken store, not a short file: stop, don't export half.
            if slice.data.isEmpty, offset < slice.size { throw Failure.unreadable(visual: id.rawValue, path: name) }
            data.append(slice.data)
            offset += Int64(slice.data.count)
            if offset >= slice.size {
                // The manifest's hash is what the bytes were final with; an empty one is "not recorded".
                if !sha256.isEmpty, SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() != sha256.lowercased() {
                    throw Failure.unreadable(visual: id.rawValue, path: name)
                }
                return data
            }
        }
    }

    /// The names the export owns (`README.md`, the alternates folder) cannot come from a manifest.
    private static func isSafe(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\0"), !path.contains("\\") else { return false }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else { return false }
        return parts[0] != Substring(alternatesDir)
    }

    /// The snapshot a plan shows for a revision: the `default` state (else the first) at the
    /// first size. Also the catalogue's snapshot path, so a round reads the picture release exports.
    public static func defaultSnapshot(_ m: VisualManifest) -> String? {
        let state = m.states.contains("default") ? "default" : (m.states.first ?? "default")
        let pngs = m.files.map(\.path).filter { $0.hasPrefix("snapshot@") && $0.hasSuffix(".png") && isSafe($0) }
        if let size = m.sizes.first, pngs.contains("snapshot@\(state)-\(size).png") { return "snapshot@\(state)-\(size).png" }
        return pngs.filter { $0.hasPrefix("snapshot@\(state)-") }.sorted().first ?? pngs.sorted().first
    }

    private static func readme(id: VisualID, manifest m: VisualManifest) -> String {
        let states = m.states.isEmpty ? "default" : m.states.joined(separator: ", ")
        var s = "# \(m.title.isEmpty ? id.rawValue : m.title)\n\n"
        s += "- Visual: `\(id.rawValue)`\n- Kind: \(m.kind)\n- States: \(states)\n\n"
        s += "Implement to match; do not redesign.\n\n## How to open it\n\n"
        s += "Snapshots (`snapshot@<state>-<size>.png`) show each state. "
        s += "Open them in any image viewer. The entry file is `\(m.entry)`"
        s += m.provider == "mermaid" ? "; it is Mermaid source, which any Mermaid renderer opens." : "."
        if m.files.contains(where: { $0.path.hasPrefix("export/") }) {
            s += " The `export/` folder is an offline bundle: open `export/index.html` in a browser if it has one."
        }
        s += "\n\n`_unused-alternates/` holds options that were not chosen.\n"
        return s
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]")
    }
}

/// The "Fidelity references" section code appends to a task's description (V-R3). Code writes it
/// so the wording and paths are the same every time; the agent only chooses which visuals.
public enum FidelityReferences {
    public static let heading = "Fidelity references (implement to match; don't redesign):"

    /// `description` unchanged when there is nothing to cite or no slug to cite under (release
    /// has not exported yet).
    public static func appending(to description: String, refs: [VisualRef]?, slug: String?) -> String {
        guard let refs, !refs.isEmpty, let slug else { return description }
        var lines = [heading]
        for ref in refs {
            var line = "- \(PlanExporter.plansRoot)/\(slug)/visuals/\(ref.visualID)/"
            if !ref.states.isEmpty { line += " \u{2014} states: " + ref.states.joined(separator: ", ") }
            lines.append(line)
        }
        let sep = description.isEmpty ? "" : "\n\n"
        return description + sep + lines.joined(separator: "\n")
    }
}
