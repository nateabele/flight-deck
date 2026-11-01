import Foundation

/// One section of a plan, in outline order. Ids are `s<n>` (R6): derived per checkpoint from the
/// headings, so `s3` names the third heading of THIS version — a thread rebuilds its workspace
/// when the plan moves, and its prompt says which version the ids belong to.
public struct PlanSection: Equatable, Sendable {
    /// `s0` for a preamble before the first heading (only when it has text), then `s1`… per heading.
    public var id: String
    /// The heading line, trimmed (`## Phase 3: …`); nil for the preamble.
    public var heading: String?
    /// The heading's words without its `#`s; "Preamble" for the preamble.
    public var title: String
    /// The heading's `#` count; 0 for the preamble.
    public var level: Int
    /// The section's text, its heading line included, up to the next heading of any level.
    public var text: String
    public var range: Range<String.Index>

    /// Lines of text, not counting the blank lines that separate it from the next heading.
    public var lineCount: Int {
        let body = text.reversed().drop { $0.isNewline || $0 == " " }
        return body.isEmpty ? 0 : body.filter(\.isNewline).count + 1
    }
}

/// Splitting a plan into sections, and the loose matching of the section labels rounds write.
public enum PlanOutline {
    /// Every heading starts a section, whatever its level: a thread anchored on a `###`
    /// subsection reads that subsection, not the whole `##` chapter around it. Headings inside
    /// fenced code are code, not structure.
    public static func sections(_ markdown: String) -> [PlanSection] {
        var starts: [(index: String.Index, heading: String?)] = []
        var fence: Substring?
        var lineStart = markdown.startIndex
        while lineStart < markdown.endIndex {
            let lineEnd = markdown[lineStart...].firstIndex(of: "\n") ?? markdown.endIndex
            let line = markdown[lineStart..<lineEnd]
            let trimmed = line.drop { $0 == " " }
            if let open = fence {
                if trimmed.hasPrefix(open) { fence = nil }
            } else if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                fence = trimmed.prefix(3)
            } else if line.hasPrefix("#"), let level = headingLevel(line) , level <= 6 {
                starts.append((lineStart, String(line).trimmingCharacters(in: .whitespaces)))
            }
            lineStart = lineEnd < markdown.endIndex ? markdown.index(after: lineEnd) : markdown.endIndex
        }
        var out: [PlanSection] = []
        let firstHeading = starts.first?.index ?? markdown.endIndex
        let preamble = markdown[..<firstHeading]
        if !preamble.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            out.append(PlanSection(id: "s0", heading: nil, title: "Preamble", level: 0, text: String(preamble),
                                   range: markdown.startIndex..<firstHeading))
        }
        for (n, start) in starts.enumerated() {
            let end = n + 1 < starts.count ? starts[n + 1].index : markdown.endIndex
            let heading = start.heading ?? ""
            out.append(PlanSection(id: "s\(n + 1)", heading: heading, title: title(of: heading),
                                   level: headingLevel(Substring(heading)) ?? 1,
                                   text: String(markdown[start.index..<end]), range: start.index..<end))
        }
        return out
    }

    /// The section holding `index`; the last one when `index` is the plan's end.
    public static func section(containing index: String.Index, in sections: [PlanSection]) -> PlanSection? {
        sections.first { $0.range.contains(index) } ?? sections.last { $0.range.upperBound == index }
    }

    /// A heading's words: `## Phase 3: durable state` → `Phase 3: durable state`.
    public static func title(of heading: String) -> String {
        String(heading.drop { $0 == "#" }).trimmingCharacters(in: .whitespaces)
    }

    /// Whether a round's section label names the section titled `title`. Rounds label changes
    /// loosely — `Phase 3 — item 2`, `Release verification`, or the full title — so a label
    /// matches when, ignoring case and the part after an em dash, it is the title or the
    /// title's start up to a word boundary (`Phase 1` names `Phase 1: …`, not `Phase 10: …`).
    public static func touches(label: String, title: String) -> Bool {
        let key = normalized(label.components(separatedBy: " — ").first ?? label)
        let full = normalized(title)
        guard !key.isEmpty else { return false }
        if key == full { return true }
        guard full.hasPrefix(key) else { return false }
        let next = full[full.index(full.startIndex, offsetBy: key.count)]
        return next == ":" || next == " " || next == "."
    }

    /// Whether two headings name the same section across versions (a draft's and the plan's):
    /// the same words, or the same numbered key before a colon (`Phase 3: …`).
    public static func sameSection(_ a: String, _ b: String) -> Bool {
        let x = normalized(title(of: a)), y = normalized(title(of: b))
        if x == y { return true }
        guard let kx = x.split(separator: ":").first, let ky = y.split(separator: ":").first,
              x.contains(":"), y.contains(":") else { return false }
        return kx == ky
    }

    static func normalized(_ s: String) -> String {
        s.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func headingLevel(_ line: Substring) -> Int? {
        let hashes = line.prefix { $0 == "#" }.count
        guard hashes > 0 else { return nil }
        let rest = line.dropFirst(hashes)
        return rest.isEmpty || rest.first == " " ? hashes : nil
    }
}

/// `provenance/<checkpoint>.md` (spec §5): what one checkpoint knows about the anchored
/// section, each item with a citation id the agent cites as `[cite:<id>]`. Ids are
/// `cp<checkpoint>.<kind><n>`: `d<i>` draft i's version of the section, `x<k>` cross-check
/// cluster k, `v<i>` the integrator's verdict on change i of `changes.json`, `n<k>` the k-th note
/// the round consumed. Each is an index into a file the round wrote once and never rewrites,
/// so an id means the same item in every rebuild and every turn.
public struct ProvenanceIndex: Equatable, Sendable {
    public enum Kind: String, Sendable { case draft, cluster, verdict, note }

    public struct Item: Equatable, Sendable {
        public var id: String
        public var kind: Kind
        public var text: String
    }

    public let checkpoint: Int
    public let label: String
    /// The anchored section's title, or nil for a whole-plan thread (every item counts).
    public let section: String?
    public let items: [Item]

    public var ids: Set<String> { Set(items.map(\.id)) }

    /// How long a draft's version of a section may run before it is cut: the file is read by the
    /// agent on demand, and one draft's whole plan is not provenance.
    static let draftExcerpt = 2400

    /// Reads checkpoint `cp`'s files from `directory` (`TapeStore.checkpointDirectory`). A
    /// missing or malformed file only drops the items it would have given.
    public static func build(checkpoint cp: Checkpoint, label: String, directory: URL, section: String?) -> ProvenanceIndex {
        var items: [Item] = []
        let prefix = "cp\(cp.id)."

        // The drafts' positions on the section.
        let drafts = directory.appendingPathComponent("drafts", isDirectory: true)
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: drafts.path)) ?? [])
            .compactMap { name -> Int? in name.hasSuffix(".md") ? Int(name.dropLast(3)) : nil }.sorted()
        for i in names {
            guard let data = try? Data(contentsOf: drafts.appendingPathComponent("\(i).md")) else { continue }
            let text = PlanLayers.readPlan(data)
            let sections = PlanOutline.sections(text)
            if let section {
                guard let match = sections.first(where: { $0.heading.map { PlanOutline.sameSection($0, section) } ?? false })
                else { continue }
                items.append(Item(id: prefix + "d\(i)", kind: .draft,
                                  text: "Draft \(i)'s version:\n\n" + excerpt(match.text)))
            } else {
                let outline = sections.compactMap(\.heading).joined(separator: "\n")
                items.append(Item(id: prefix + "d\(i)", kind: .draft, text: "Draft \(i)'s outline:\n\n" + outline))
            }
        }

        // The round's proposals that touch the section, with the integrator's verdict on each.
        let changes = load([ProposedChange].self, directory.appendingPathComponent("changes.json")) ?? []
        let verdicts = (load([ChangeVerdict].self, directory.appendingPathComponent("verdicts.json")) ?? [])
            .reduce(into: [Int: Verdict]()) { $0[$1.index] = $0[$1.index] ?? $1.verdict }
        let crossCheck = load(CrossCheckRecord.self, directory.appendingPathComponent(CrossCheckRecord.fileName))
        func touches(_ i: Int) -> Bool { section.map { PlanOutline.touches(label: changes[i].section, title: $0) } ?? true }
        func proposer(_ i: Int) -> String? {
            guard let cc = crossCheck, cc.proposers.indices.contains(i), cc.families.indices.contains(cc.proposers[i])
            else { return nil }
            return cc.families[cc.proposers[i]].rawValue
        }

        // Clusters first: an issue two reviewers raised separately is the strongest signal here.
        for (k, cluster) in (IssueClusters.clean(crossCheck?.clusters, count: changes.count) ?? []).enumerated()
            where cluster.contains(where: touches) {
            let members = cluster.map { i in
                "- [cite:\(prefix)v\(i)] \(changes[i].section)\(proposer(i).map { " (\($0))" } ?? ""): \(changes[i].rationale)"
            }
            items.append(Item(id: prefix + "x\(k)", kind: .cluster,
                              text: "One issue, raised by \(cluster.count) proposals:\n" + members.joined(separator: "\n")))
        }
        for i in changes.indices where touches(i) {
            let verdict = verdicts[i].map(\.rawValue) ?? "no verdict"
            let by = proposer(i).map { ", proposed by \($0)" } ?? ""
            items.append(Item(id: prefix + "v\(i)", kind: .verdict,
                              text: "\(verdict)\(by) — \(changes[i].section)\n  Why: \(changes[i].rationale)\n  Edit: \(changes[i].edit)"))
        }

        // The notes the round consumed: anchored ones in the section, and every whole-plan one.
        for (k, note) in cp.record.annotations.enumerated() {
            if let section, let anchored = note.anchor?.section, !PlanOutline.sameSection(anchored, section) { continue }
            let quote = note.anchor.map { " on “\($0.quote)”" } ?? " on the whole plan"
            let words = note.note.isEmpty ? "" : ": \(note.note)"
            items.append(Item(id: prefix + "n\(k)", kind: .note, text: "\(note.kind.rawValue)\(quote)\(words)"))
        }
        return ProvenanceIndex(checkpoint: cp.id, label: label, section: section, items: items)
    }

    /// The file's text. An empty index still says so, so the agent doesn't go looking.
    public var markdown: String {
        var s = "# Checkpoint \(checkpoint): \(label)\n\n"
        s += section.map { "What this checkpoint records about “\($0)”.\n" } ?? "What this checkpoint records about the plan.\n"
        guard !items.isEmpty else { return s + "\nNothing here touches it.\n" }
        for kind in [Kind.draft, .cluster, .verdict, .note] {
            let these = items.filter { $0.kind == kind }
            guard !these.isEmpty else { continue }
            s += "\n## " + ["draft": "Drafts", "cluster": "Cross-check clusters", "verdict": "Proposed changes and verdicts",
                            "note": "Notes this round consumed"][kind.rawValue]! + "\n"
            for item in these { s += "\n[cite:\(item.id)] \(item.text)\n" }
        }
        return s
    }

    /// Every `[cite:<id>]` in `text`, in order. The UI links an id only when the thread's
    /// workspace holds it (spec §5); any other is shown as plain text.
    public static func citations(in text: String) -> [String] {
        var out: [String] = []
        var rest = text[...]
        while let open = rest.range(of: "[cite:") {
            rest = rest[open.upperBound...]
            guard let close = rest.firstIndex(of: "]") else { break }
            let id = rest[..<close]
            if !id.isEmpty, id.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_" }) {
                out.append(String(id))
            }
            rest = rest[rest.index(after: close)...]
        }
        return out
    }

    private static func excerpt(_ text: String) -> String {
        text.count <= draftExcerpt ? text : String(text.prefix(draftExcerpt)) + "\n… (cut; the draft file has the rest)"
    }

    private static func load<T: Decodable>(_ type: T.Type, _ url: URL) -> T? {
        (try? Data(contentsOf: url)).flatMap { try? IntakeJSON.decoder.decode(type, from: $0) }
    }
}
