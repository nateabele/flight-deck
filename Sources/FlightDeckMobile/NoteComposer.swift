import FleetKit
import Foundation

/// The note drafting rules: which kinds exist, when one can be added, and what goes on the wire.
enum NoteComposer {
    static let kinds: [(id: String, title: String)] = [
        ("comment", "Comment"), ("question", "Question"), ("mustChange", "Must change"),
        ("replace", "Replace"), ("delete", "Delete"), ("highlight", "Highlight"),
    ]

    /// A highlight carries no text of its own; every other kind needs some.
    static func canAdd(kind: String, text: String) -> Bool {
        kind == "highlight" || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The Mac has no "highlight" kind: it is a comment on the selection, sent at once.
    static func wire(kind: String) -> (kind: String, sendsImmediately: Bool) {
        kind == "highlight" ? ("comment", true) : (kind, false)
    }

    static func notesAllowed(detail: WireIntakeDetail?) -> Bool {
        detail?.steer == true && detail?.summary.state == "shaping"
    }

    /// Whether a note's type can be changed from its row: it must still be pending (a round
    /// that has read a note read it as what it was), the intake must take notes, and the Mac
    /// must understand `intake.setNoteKind` — an older one drops the socket on the unknown op.
    static func canRetype(_ note: WireNote, detail: WireIntakeDetail?) -> Bool {
        !note.consumed && notesAllowed(detail: detail) && detail?.noteKind == true
    }

    /// The types the row's menu offers: the five a note can be, without the composer's
    /// Highlight (which is a comment with no words, so it is the Comment item when empty).
    static let retypeKinds = kinds.filter { $0.id != "highlight" }

    /// Whether a note with `text` can become `kind` and still say something: the Mac's rule
    /// (`PlanNote.accepts(kind:)`) — every type needs words but Comment and Delete.
    static func accepts(kind: String, text: String) -> Bool {
        kind == "comment" || kind == "delete" || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

extension NoteComposer {
    /// The checkpoint a note carries (R3). A passage note names the checkpoint the reader
    /// showed, because its block index only means something in that checkpoint's split; a
    /// plan-wide note carries neither, since the Mac refuses a block without a checkpoint and a
    /// checkpoint without a block would anchor nothing.
    static func checkpoint(for target: NoteDraftTarget, showing: Int) -> Int? {
        target.block == nil ? nil : showing
    }

    /// The kinds the sheet offers. A Highlight is an empty comment on a selection; on the whole
    /// plan it would be a note that says nothing about nothing, so the plan-wide sheet drops it.
    static func kinds(for target: NoteDraftTarget) -> [(id: String, title: String)] {
        target.block == nil ? kinds.filter { $0.id != "highlight" } : kinds
    }
}

/// What a note is about: a passage (`block`), optionally a phrase in it (`quote`, the rendered
/// text the maintainer selected), or the whole plan (both nil).
struct NoteDraftTarget: Equatable {
    let block: Int?
    let quote: String?
}

/// One note being composed. `id` is the note's wire id, fixed when the draft is made and never
/// minted inside a send: a retry after a lost ack must be the same note, or the Mac — which
/// dedupes on the token, not the text — would still hold the first and the phone would think
/// the second is a different one.
///
/// `checkpoint` is decided when the draft is made, from the plan the reader was SHOWING then:
/// the block index was read off that split, so a head that moved on while the sheet was open
/// must not re-label it.
struct NoteDraft: Identifiable, Equatable {
    let id: UUID
    let target: NoteDraftTarget
    let checkpoint: Int?
    var kind: String
    var text: String

    init(id: UUID = UUID(), target: NoteDraftTarget, showing: Int, kind: String = "comment", text: String = "") {
        self.id = id; self.target = target; self.kind = kind; self.text = text
        self.checkpoint = NoteComposer.checkpoint(for: target, showing: showing)
    }

    /// The note as the plan will list it once the Mac has it.
    var wireNote: WireNote {
        WireNote(id: id, kind: NoteComposer.wire(kind: kind).kind,
                 text: text.trimmingCharacters(in: .whitespacesAndNewlines),
                 quote: target.quote, consumed: false, blockIndex: target.block)
    }
}

/// The notes this reader sent that the plan does not list yet.
///
/// **Why an acked note needs holding on to.** The Mac's plan projection reads the tape's
/// pending notes, and a note the phone just sent is only a queued command until a runner folds
/// it — so the head re-requested on the ack can come back without it. Without this the note
/// would flash, vanish, and reappear a round later, and could not be withdrawn in between even
/// though the Mac would accept the withdrawal (`IntakeService.pendingNotes` folds the queue).
struct NoteOutbox: Equatable {
    private struct Entry: Equatable {
        var draft: NoteDraft
        var acked = false
    }
    private var entries: [Entry] = []

    /// Sent or sending, not yet acked: drawn with "Not yet sent", or the failure.
    var unsent: [NoteDraft] { entries.filter { !$0.acked }.map(\.draft) }
    /// Acked and not yet in the plan: drawn as any other pending note.
    var sentNotes: [WireNote] { entries.filter(\.acked).map(\.draft.wireNote) }

    /// Add a draft, or replace it (a retry is the same note).
    mutating func submit(_ draft: NoteDraft) {
        if let i = entries.firstIndex(where: { $0.draft.id == draft.id }) {
            entries[i] = Entry(draft: draft)
        } else {
            entries.append(Entry(draft: draft))
        }
    }

    mutating func acked(_ id: UUID) {
        if let i = entries.firstIndex(where: { $0.draft.id == id }) { entries[i].acked = true }
    }

    mutating func remove(_ id: UUID) { entries.removeAll { $0.draft.id == id } }

    /// Types the reader changed that the plan does not show yet, by note id. The plan's notes
    /// are the tape's pending ones, and a retype is only a queued command until a runner folds
    /// it — so the head re-requested on the ack can still carry the old type.
    private var retyped: [UUID: String] = [:]

    /// Change a note's type. A note the plan does not list yet carries it in its draft, so its
    /// card and a retry both say the new one; a plan note is relabelled by `listing`.
    mutating func retype(_ id: UUID, to kind: String) {
        retyped[id] = kind
        if let i = entries.firstIndex(where: { $0.draft.id == id }) { entries[i].draft.kind = kind }
    }

    /// The plan's notes with this reader's acked ones and its retypes on top: what to draw.
    func listing(_ planNotes: [WireNote]) -> [WireNote] {
        (planNotes + sentNotes).map { note in
            var note = note
            if let kind = retyped[note.id], !note.consumed { note.kind = kind }
            return note
        }
    }

    /// A Delete that failed. Refused as `note_consumed`, it can never succeed — a round has read
    /// the note, or the Mac never had it — so the card goes rather than offering a Delete that
    /// fails forever. Any other failure leaves it for another try.
    mutating func removeFailed(_ id: UUID, error: FleetRequestError?) {
        if error == .server(code: "note_consumed") { remove(id) }
    }

    /// Drop every note the plan now lists: from here the plan is the record.
    mutating func reconcile(with notes: [WireNote]) {
        let listed = Set(notes.map(\.id))
        entries.removeAll { listed.contains($0.draft.id) }
        // Settled once the plan shows the type (or the note is gone or was read): from here the
        // plan is the record.
        retyped = retyped.filter { id, kind in notes.contains { $0.id == id && !$0.consumed && $0.kind != kind } }
    }
}
