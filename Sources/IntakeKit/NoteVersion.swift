import Foundation

extension Stage {
    /// What the app calls a round's plan wherever it names one: "Draft", "Synthesis",
    /// "Refine 2", "Polish 1" — the board, the read-only bar, the phone, and a note's version.
    public func versionName(round: Int) -> String {
        switch self {
        case .draft: "Draft"
        case .synthesis: "Synthesis"
        case .refine: "Refine \(round)"
        case .encode: "Encode"
        case .polish: "Polish \(round)"
        case .freshEyes: "Fresh eyes"
        case .dedup: "Dedup"
        }
    }
}

/// The version of the plan a note was written on. A note is pinned to it: the plan moves on
/// under it (synthesis rewrites the text, a refine round rewrites it again), and a quote that
/// is gone from the plan being read is not a lost note, only a note about an earlier version.
public enum NoteVersion {
    /// "Draft · Round 0", "Refine 1": the stage's name, with its round when the name does not
    /// carry one already.
    public static func label(of checkpoint: Checkpoint) -> String {
        label(stage: checkpoint.stage, round: checkpoint.round)
    }

    public static func label(stage: Stage, round: Int) -> String {
        let name = stage.versionName(round: round)
        return name.last?.isNumber == true ? name : "\(name) · Round \(round)"
    }

    /// The checkpoint `entry` was written on; nil for a note about the whole plan, and for one
    /// whose version can be neither read nor inferred.
    ///
    /// A note records it: `NoteAnchor.checkpoint`, the checkpoint whose plan the quote was
    /// selected in, which is also the plan its context and section describe. That is used
    /// whenever the tape has that checkpoint. Otherwise (an anchor written with an id the tape
    /// does not hold) it is inferred from what a note does carry. A note has no clock of its own,
    /// but the round that read it started after it was written, so its candidates are the
    /// checkpoints before that round (every checkpoint, for a note still pending): the latest
    /// whose plan contains the quote, else simply the latest. Computed on read, never saved.
    public static func resolve(_ entry: TapeNote, checkpoints: [Checkpoint], planText: (Int) -> String?) -> Int? {
        guard let anchor = entry.note.anchor else { return nil }
        if checkpoints.contains(where: { $0.id == anchor.checkpoint }) { return anchor.checkpoint }
        let consumer = entry.consumedBy.flatMap { id in checkpoints.first { $0.id == id } }
        let bound = consumer.map { $0.startedAt ?? $0.createdAt }
        let before = checkpoints.filter { c in
            if let consumer, c.id >= consumer.id { return false }
            if let bound, c.createdAt > bound { return false }
            return true
        }.sorted { $0.id < $1.id }
        return before.last { c in planText(c.id).map { anchor.locate(in: $0) != nil } ?? false }?.id ?? before.last?.id
    }
}
