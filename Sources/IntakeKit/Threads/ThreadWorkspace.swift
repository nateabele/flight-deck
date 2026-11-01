import Foundation

/// `threads/<id>/workspace/` (spec §5): the plan a thread follows, cut into files the agent reads
/// on demand with its own read tools (D6), rebuilt for every turn from the checkpoint the thread
/// follows. The first turn's prompt carries only the outline, the anchor and its section, and an
/// index of the rest, so a long plan costs the agent nothing it doesn't open.
///
/// | file | contents |
/// |---|---|
/// | `outline.md` | `s<n>` ids, headings and sizes |
/// | `sections/s<n>.md` | one per section |
/// | `anchor.md` | the anchored quote and its section |
/// | `intake.md` | the request and the triage Q&A |
/// | `provenance/<cp>.md` | per checkpoint, what it records about the anchored section (`ProvenanceIndex`) |
/// | `citations.json` | every citation id the provenance files hold, for the UI to link |
public struct ThreadWorkspace: Equatable, Sendable {
    public let directory: URL
    public let checkpoint: Int
    public let label: String
    public let sections: [PlanSection]
    /// The section the thread is anchored in; nil for a whole-plan thread, or when the anchored
    /// quote no longer appears in this version.
    public let anchored: PlanSection?
    public let anchorText: String
    public let outline: String
    public let citationIDs: Set<String>
    /// The other files, relative to `directory`, for the first turn's index.
    public let files: [String]

    public static let citationsName = "citations.json"

    /// Builds the workspace into `directory`, replacing whatever an earlier turn left there.
    /// `plan` is checkpoint `checkpoint`'s effective plan; `tape` supplies the provenance of
    /// every checkpoint up to it.
    public static func build(in directory: URL, anchor: ThreadAnchor, checkpoint: Int, plan: String, tape: Tape,
                             store: TapeStore, intake: Intake?) throws -> ThreadWorkspace {
        let fm = FileManager.default
        // A trashed intake's thread gets no workspace (A-I1): this would recreate it at the old path.
        try IntakeDirectory.require(store.intakeDirectory)
        if fm.fileExists(atPath: directory.path) { try fm.removeItem(at: directory) }
        try fm.createDirectory(at: directory.appendingPathComponent("sections", isDirectory: true),
                               withIntermediateDirectories: true)
        try fm.createDirectory(at: directory.appendingPathComponent("provenance", isDirectory: true),
                               withIntermediateDirectories: true)

        let sections = PlanOutline.sections(plan)
        let anchored = anchoredSection(anchor, plan: plan, sections: sections)
        let label = tape.checkpoints.first { $0.id == checkpoint }.map(Self.label) ?? "Checkpoint \(checkpoint)"
        var files: [String] = []
        func write(_ name: String, _ text: String) throws {
            try Data(text.utf8).write(to: directory.appendingPathComponent(name), options: .atomic)
        }

        let outline = outlineText(sections, checkpoint: checkpoint, label: label, anchored: anchored)
        try write("outline.md", outline)
        for section in sections {
            try write("sections/\(section.id).md", section.text)
            files.append("sections/\(section.id).md")
        }
        let anchorText = anchorText(anchor, anchored: anchored)
        try write("anchor.md", anchorText)
        try write("intake.md", intakeText(intake))
        files.append("intake.md")

        var ids = Set<String>()
        for cp in tape.checkpoints where cp.id <= checkpoint {
            let index = ProvenanceIndex.build(checkpoint: cp, label: Self.label(cp),
                                              directory: store.checkpointDirectory(cp.id),
                                              section: anchored.map(\.title))
            try write("provenance/\(cp.id).md", index.markdown)
            files.append("provenance/\(cp.id).md")
            ids.formUnion(index.ids)
        }
        try IntakeJSON.encoder.encode(ids.sorted()).write(to: directory.appendingPathComponent(citationsName), options: .atomic)
        return ThreadWorkspace(directory: directory, checkpoint: checkpoint, label: label, sections: sections,
                               anchored: anchored, anchorText: anchorText, outline: outline, citationIDs: ids,
                               files: files)
    }

    /// The citation ids a built workspace holds, read back from its `citations.json` (empty when
    /// there is none) — for a reader in another process.
    public static func citationIDs(in directory: URL) -> Set<String> {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(citationsName)),
              let ids = try? IntakeJSON.decoder.decode([String].self, from: data) else { return [] }
        return Set(ids)
    }

    /// The name a checkpoint goes by in a divider and a header: "Refine 3", "Synthesis".
    public static func label(_ cp: Checkpoint) -> String {
        switch cp.stage {
        case .draft: "Draft"
        case .synthesis: "Synthesis"
        case .refine: "Refine \(cp.round)"
        case .encode: "Encode"
        case .polish: "Polish \(cp.round)"
        case .freshEyes: "Fresh eyes"
        case .dedup: "Dedup"
        }
    }

    /// The section the anchor's quote sits in on this version, found the way a note is found
    /// (`NoteAnchor.locate`); failing that, the section whose heading the anchor recorded.
    static func anchoredSection(_ anchor: ThreadAnchor, plan: String, sections: [PlanSection]) -> PlanSection? {
        guard let note = anchor.note else { return nil }
        if let range = note.locate(in: plan) { return PlanOutline.section(containing: range.lowerBound, in: sections) }
        guard let heading = note.section else { return nil }
        return sections.first { $0.heading.map { PlanOutline.sameSection($0, heading) } ?? false }
    }

    private static func outlineText(_ sections: [PlanSection], checkpoint: Int, label: String,
                                    anchored: PlanSection?) -> String {
        var s = "# Outline of checkpoint \(checkpoint) (\(label))\n\nSection ids belong to this version only.\n\n"
        for section in sections {
            let indent = String(repeating: "  ", count: max(section.level - 1, 0))
            let mark = section.id == anchored?.id ? "  ← the thread's anchor" : ""
            s += "\(indent)- \(section.id) \(section.heading ?? "(preamble)") — \(section.lineCount) lines\(mark)\n"
        }
        return s
    }

    private static func anchorText(_ anchor: ThreadAnchor, anchored: PlanSection?) -> String {
        guard let note = anchor.note else {
            return "# Anchor\n\nThis thread is about the whole plan.\n"
        }
        var s = "# Anchor\n\nThe human highlighted:\n\n> " + note.quote.replacingOccurrences(of: "\n", with: "\n> ") + "\n"
        if let anchored {
            s += "\nIt is in \(anchored.id), “\(anchored.title)”. That section:\n\n" + anchored.text + "\n"
        } else {
            s += "\nThat passage is not in this version of the plan any more"
                + (note.section.map { "; it was under “\($0)”." } ?? ".") + "\n"
        }
        return s
    }

    private static func intakeText(_ intake: Intake?) -> String {
        guard let intake else { return "# Intake\n\n(The intake could not be read.)\n" }
        var s = "# Intake\n\n## Request\n\n\(intake.intent)\n"
        let pairs = intake.exchanges.flatMap { exchange -> [String] in
            let answers = exchange.answers ?? []
            return exchange.questions.enumerated().map { i, q in
                "Q: \(q)\nA: \(i < answers.count ? answers[i] : "(unanswered)")"
            }
        }
        if !pairs.isEmpty { s += "\n## Triage Q&A\n\n" + pairs.joined(separator: "\n\n") + "\n" }
        return s
    }
}
