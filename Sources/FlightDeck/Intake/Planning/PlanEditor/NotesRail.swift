import AppKit
import IntakeKit
import SwiftUI

/// One card on the notes rail (spec §7.3). `anchorY` is where its quote's line sits, in the
/// rail's own coordinates; nil for a note with no place beside the text — unanchored, detached,
/// or with the editor not on screen to measure.
struct NoteCardModel: Equatable, Identifiable {
    let id: UUID
    let kind: NoteKind
    let quote: String?
    let note: String
    var anchorY: CGFloat?
    /// Its quote can't be found in the plan any more: shown at the top, never dropped.
    let detached: Bool
    /// An earlier round already read it: dimmed and read-only (`.removeNote` only withdraws a
    /// pending note — the prompt it shaped can't be taken back).
    let consumed: Bool
}

/// The rail decided without a view: which cards, in what order, where each sits, and the words
/// for the summary chip and the next-round tooltip. Pure, so `NotesRailModelTests` pins it.
enum NotesRailModel {
    /// Pending notes first, then the ones earlier rounds consumed. Within each: notes with no
    /// place in the text — detached (their quote is gone), then unanchored (about the whole
    /// plan) — at the top, then anchored notes in document order. A detached note keeps its
    /// quote: that is how the human recognises what it was about.
    static func cards(notes: [TapeNote], plan: String,
                      lineY: (Range<String.Index>) -> CGFloat?) -> [NoteCardModel] {
        cards(notes: notes, located: { entry in entry.note.anchor?.locate(in: plan).map { NSRange($0, in: plan) } },
              lineY: { range in Range(range, in: plan).flatMap(lineY) })
    }

    /// The same, with each note's quote already found (`located`, nil when it can't be) — the
    /// rail's own form: it redraws on every scroll beat, and finding every quote in a long plan
    /// on each one was most of the cost of a scroll.
    static func cards(notes: [TapeNote], located: (TapeNote) -> NSRange?,
                      lineY: (NSRange) -> CGFloat?) -> [NoteCardModel] {
        func group(_ notes: [TapeNote], consumed: Bool) -> [NoteCardModel] {
            var detached: [NoteCardModel] = [], unanchored: [NoteCardModel] = []
            var anchored: [(at: Int, card: NoteCardModel)] = []
            for entry in notes {
                let note = entry.note
                guard let anchor = note.anchor else {
                    unanchored.append(NoteCardModel(id: note.id, kind: note.kind, quote: nil, note: note.note,
                                                    anchorY: nil, detached: false, consumed: consumed))
                    continue
                }
                guard let range = located(entry) else {
                    detached.append(NoteCardModel(id: note.id, kind: note.kind, quote: anchor.quote, note: note.note,
                                                  anchorY: nil, detached: true, consumed: consumed))
                    continue
                }
                anchored.append((range.location,
                                 NoteCardModel(id: note.id, kind: note.kind, quote: anchor.quote, note: note.note,
                                               anchorY: lineY(range), detached: false, consumed: consumed)))
            }
            // Stable: two notes on the same quote keep the order they were made in.
            let ordered = anchored.enumerated().sorted { ($0.element.at, $0.offset) < ($1.element.at, $1.offset) }
            return detached + unanchored + ordered.map(\.element.card)
        }
        return group(notes.filter { $0.consumedBy == nil }, consumed: false)
            + group(notes.filter { $0.consumedBy != nil }, consumed: true)
    }

    /// "4 notes for the next round" for the chip (nil with no pending notes), and "Sends your 3
    /// edits and 4 notes" for the play keys' tooltip (nil when the next round gets nothing of
    /// the human's). Counts, never estimates.
    static func summary(pending: Int, edits: Int) -> (chip: String?, tooltip: String?) {
        let notes = "\(pending) note\(pending == 1 ? "" : "s")"
        let changes = "\(edits) edit\(edits == 1 ? "" : "s")"
        let chip = pending > 0 ? "\(notes) for the next round" : nil
        let parts = (edits > 0 ? [changes] : []) + (pending > 0 ? [notes] : [])
        return (chip, parts.isEmpty ? nil : "Sends your " + parts.joined(separator: " and "))
    }

    /// Where each placeable card's top goes: on its anchor's line, or pushed down just far
    /// enough to clear the card above it (in anchor order) by `minGap`. Cards without an
    /// `anchorY` aren't placed — the rail stacks those at its top. A card with no measured
    /// height counts as zero tall, so two cards never share a Y even before measurement.
    static func layout(_ cards: [NoteCardModel], heights: [UUID: CGFloat] = [:], minGap: CGFloat) -> [UUID: CGFloat] {
        let placeable = cards.enumerated().compactMap { i, card in card.anchorY.map { (i, $0, card.id) } }
            .sorted { ($0.1, $0.0) < ($1.1, $1.0) }
        var out: [UUID: CGFloat] = [:]
        var floor = -CGFloat.infinity
        for (_, y, id) in placeable {
            let top = max(y, floor)
            out[id] = top
            floor = top + (heights[id] ?? 0) + minGap
        }
        return out
    }

    /// Whether a draft says enough to send: some text — except Delete, whose kind is the whole
    /// request. Replace without its replacement would ask the round to guess.
    static func draftCommits(kind: NoteKind, text: String) -> Bool {
        kind == .delete || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// The words and symbols each kind wears — shared by the selection toolbar, the cards and the
/// band's hover. Kinds are told apart by these alone, never by colour (HIG ruling, W4): every
/// note's band is the one system highlight, so a plan with five kinds of note doesn't read as
/// five competing colour codes, and Delete isn't the red of an error or of a deletion ghost.
enum NoteStyle {
    static let kinds: [NoteKind] = [.comment, .question, .mustChange, .replace, .delete]

    static func label(_ kind: NoteKind) -> String {
        switch kind {
        case .comment: "Comment"
        case .question: "Question"
        case .mustChange: "Must change"
        case .replace: "Replace"
        case .delete: "Delete"
        }
    }

    static func symbol(_ kind: NoteKind) -> String {
        switch kind {
        case .comment: "text.bubble"
        case .question: "questionmark.bubble"
        case .mustChange: "exclamationmark.bubble"
        case .replace: "arrow.left.arrow.right"
        case .delete: "delete.left"
        }
    }

    static func placeholder(_ kind: NoteKind) -> String {
        switch kind {
        case .comment: "Add a comment"
        case .question: "Ask the next round"
        case .mustChange: "What must change?"
        case .replace: "Replace it with…"
        case .delete: "Why cut it? (optional)"
        }
    }

    /// Every note's highlight: the system's find-highlight yellow, at a subtle strength under
    /// the text (dimmer once a round has read the note).
    static let highlight = NSColor.findHighlightColor
    static let highlightAlpha: CGFloat = 0.3
    static let consumedAlpha: CGFloat = 0.16

    /// The "4 notes for the next round" chip: neutral, like any other count in the header —
    /// yellow read as a warning, and as one more kind colour.
    static let chipForeground = NSColor.secondaryLabelColor
    static let chipFill = NSColor.labelColor.withAlphaComponent(0.07)

    /// What the band says under the pointer: the kind, then the note.
    static func hover(kind: NoteKind, note: String) -> String {
        note.isEmpty ? (kind == .comment ? "Highlight" : label(kind)) : "\(label(kind)): \(note)"
    }
}

extension View {
    /// The notes chip's neutral capsule (`NoteStyle.chipFill`), matching the plan header's
    /// other chips in size.
    func notesChipStyle() -> some View {
        background(Color(nsColor: NoteStyle.chipFill), in: Capsule())
            .foregroundStyle(Color(nsColor: NoteStyle.chipForeground))
    }
}

/// What the editor tints: every visible note with an anchor, and the draft being written.
struct NoteMark: Equatable {
    let id: UUID
    let kind: NoteKind
    let anchor: NoteAnchor
    let consumed: Bool
    let draft: Bool
}

/// A note being written in the rail: created by a toolbar kind (or ✎ with no selection) and sent
/// only when committed.
struct NoteDraft: Equatable {
    let id = UUID()
    var kind: NoteKind
    let anchor: NoteAnchor?
    var text = ""
}

/// Scroll, resize and edit beats — its own object so only the rail's aligned lane redraws on
/// every scroll event, not the inspector or the detail pane around it.
///
/// At most one beat a frame: a trackpad scroll posts a bounds change for every clip view it
/// moves, several per frame, and each beat re-lays the whole rail.
@MainActor
final class NotesGeometry: ObservableObject {
    @Published private(set) var beat = 0
    static let frame: TimeInterval = 1.0 / 60
    private var scheduled = false
    private var last = Date.distantPast

    func bump() {
        guard !scheduled else { return }
        scheduled = true
        let wait = max(0, Self.frame - Date().timeIntervalSince(last))
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.scheduled = false
                self.last = Date()
                self.beat &+= 1
            }
        }
    }
}

/// The state the editor, the selection toolbar and the rail share for one intake. The detail
/// pane holds it in `@State` (not `@StateObject`) so its own body doesn't re-render on a draft
/// keystroke; the views that draw notes observe it.
///
/// Sent notes and removals are shown at once, before the runner folds them into the tape:
/// with no live runner a `.note` sits unread in `commands.jsonl` until the next tick starts one,
/// and a rail that waited for the tape would swallow the human's note for seconds.
@MainActor
final class PlanNotesController: ObservableObject {
    let geometry = NotesGeometry()

    @Published var draft: NoteDraft? { didSet { if draft?.kind != oldValue?.kind || draft?.id != oldValue?.id { marksChanged() } } }
    /// The rail has the inspector: the human is working in the plan (spec §3). Set when the
    /// editor takes focus or a draft starts; the detail pane clears it when a seat is chosen.
    @Published var planFocused = false
    /// The human's edit hunks on the plan head — the "3 edits" of the next-round tooltip.
    @Published private(set) var edits = 0
    @Published var tapeNotes: [TapeNote] = [] { didSet { if tapeNotes != oldValue { prune() } } }
    @Published private var sent: [PlanNote] = []
    @Published private var removed: Set<UUID> = []

    /// Queues a command for this intake's runner; bound by the detail pane.
    var send: (TapeCommand) -> Void = { _ in }
    /// Opens the inspector so a draft started from the toolbar has somewhere to be written.
    var showRail: () -> Void = {}
    /// The checkpoint whose plan the editor shows — what a new anchor is selected in.
    var checkpoint: Int?
    /// The editor's text as it stands, typed-but-uncommitted edits included: anchors are
    /// located in what the human sees.
    private(set) var plan = ""
    /// The editor's selection, for ✎ Annotate: with text selected it comments on it.
    var selection: NSRange?
    /// The top edge of a range's first line in window coordinates (y up); set by the editor.
    var lineTop: ((NSRange) -> CGFloat?)?
    /// The editor re-tints when the marks change.
    var onMarksChanged: (() -> Void)?
    /// Where each mark's quote is in `plan` (absent: can't be found) — found by the editor,
    /// which keeps them across keystrokes, so the rail never searches the plan itself.
    private(set) var located: [UUID: NSRange] = [:]
    /// The editor's undo stack: adding and removing a note are undoable where the human is
    /// working (⌘Z in the plan), each undo sending the command that reverses it.
    weak var undoManager: UndoManager?

    /// Every note to show: the tape's, minus the ones withdrawn, plus the ones sent that the
    /// tape doesn't hold yet.
    var notes: [TapeNote] {
        let onTape = Set(tapeNotes.map(\.id))
        return tapeNotes.filter { !removed.contains($0.id) }
            + sent.filter { !onTape.contains($0.id) && !removed.contains($0.id) }.map { TapeNote(note: $0, consumedBy: nil) }
    }

    var pendingCount: Int { notes.filter { $0.consumedBy == nil }.count }

    var summary: (chip: String?, tooltip: String?) { NotesRailModel.summary(pending: pendingCount, edits: edits) }

    var marks: [NoteMark] {
        var out = notes.compactMap { entry in
            entry.note.anchor.map { NoteMark(id: entry.id, kind: entry.note.kind, anchor: $0, consumed: entry.consumedBy != nil, draft: false) }
        }
        if let draft, let anchor = draft.anchor {
            out.append(NoteMark(id: draft.id, kind: draft.kind, anchor: anchor, consumed: false, draft: true))
        }
        return out
    }

    /// A different intake: nothing of the last one's carries over.
    func reset() {
        draft = nil
        sent = []
        removed = []
        tapeNotes = []
        planFocused = false
        edits = 0
        checkpoint = nil
        selection = nil
    }

    /// A toolbar choice on `range` of `text`. A kind starts a focused draft in the rail;
    /// Highlight (nil) is sent at once as an empty comment — the tint is the whole note.
    func choose(_ kind: NoteKind?, range: NSRange, in text: String) {
        guard let checkpoint, let span = Range(range, in: text), !span.isEmpty else { return }
        let anchor = NoteAnchor(checkpoint: checkpoint, selecting: span, in: text)
        guard let kind else { return submit(PlanNote(kind: .comment, note: "", anchor: anchor)) }
        begin(NoteDraft(kind: kind, anchor: anchor))
    }

    /// ✎ Annotate: a comment on the selection if there is one, else a note about the whole plan.
    func annotate() {
        if let selection, selection.length > 0 { return choose(.comment, range: selection, in: plan) }
        begin(NoteDraft(kind: .comment, anchor: nil))
    }

    /// The heatmap's "Annotate §N…": a comment anchored on that section's heading line, so the
    /// note sits beside the section and the next round is told which one — rather than on
    /// whatever happened to be selected. `section` is the heading line, trimmed (the heatmap's
    /// key); a heading no longer in the plan falls back to a note about the whole plan.
    func annotate(section: String) {
        let ns = plan as NSString
        var location = 0
        while location < ns.length {
            let line = ns.lineRange(for: NSRange(location: location, length: 0))
            let content = ns.substring(with: line).trimmingCharacters(in: .whitespacesAndNewlines)
            if content.hasPrefix("#"), content == section || HeatmapModel.label(content) == HeatmapModel.label(section),
               let checkpoint,
               let heading = Range(NSRange(location: line.location, length: (content as NSString).length), in: plan) {
                // The trimmed line starts where the line does: a heading has no leading space.
                var anchor = NoteAnchor(checkpoint: checkpoint, selecting: heading, in: plan)
                // Its section is the one it heads — the constructor's "heading above the
                // quote" would name the section before it, and tell the round the wrong one.
                anchor.section = content
                return begin(NoteDraft(kind: .comment, anchor: anchor))
            }
            location = NSMaxRange(line)
        }
        begin(NoteDraft(kind: .comment, anchor: nil))
    }

    private func begin(_ next: NoteDraft) {
        commitDraft()
        draft = next
        planFocused = true
        showRail()
    }

    /// ⌘↩, or the draft's field losing focus: sent when it says something, dropped otherwise.
    func commitDraft() {
        guard let draft else { return }
        self.draft = nil
        guard NotesRailModel.draftCommits(kind: draft.kind, text: draft.text) else { return }
        submit(PlanNote(id: draft.id, kind: draft.kind, note: draft.text.trimmingCharacters(in: .whitespacesAndNewlines),
                        anchor: draft.anchor))
    }

    /// Esc: nothing is sent.
    func cancelDraft() { draft = nil }

    func remove(_ id: UUID) {
        let note = notes.first { $0.id == id }?.note
        removed.insert(id)
        // Not only hidden: an optimistic note the tape never held would otherwise come back
        // the moment `prune` forgets the removal (it keeps only removals the tape still holds).
        sent.removeAll { $0.id == id }
        marksChanged()
        send(.removeNote(id))
        guard let note, let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { $0.submit(note) }
        // Undoing an add registers this as its redo, which is still "Add Note".
        undoManager.setActionName(undoManager.isUndoing ? "Add Note" : "Remove Note")
    }

    private func submit(_ note: PlanNote) {
        removed.remove(note.id)
        if !sent.contains(where: { $0.id == note.id }) { sent.append(note) }
        marksChanged()
        send(.note(note))
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { $0.remove(note.id) }
        undoManager.setActionName(undoManager.isUndoing ? "Remove Note" : "Add Note")
    }

    /// The editor loaded or changed its text; `located` is where each mark's quote now is.
    func editorChanged(_ text: String, located: [UUID: NSRange] = [:]) {
        plan = text
        self.located = located
        geometry.bump()
    }

    /// The human's edit hunks on the plan head — `EditLayer.chip`'s count, from the plan section.
    func setEdits(_ count: Int) {
        if count != edits { edits = count }
    }

    /// Optimistic entries the tape now holds (or no longer holds, for removals) are dropped.
    private func prune() {
        let onTape = Set(tapeNotes.map(\.id))
        sent.removeAll { onTape.contains($0.id) }
        removed = removed.filter { onTape.contains($0) }
        marksChanged()
    }

    private func marksChanged() { onMarksChanged?() }
}

/// The notes rail (spec §7.3): the inspector column while the plan is focused. Cards sit beside
/// their quote's line and follow the editor as it scrolls; notes with no place in the text are
/// stacked at the top; the draft being written is a card like the others, focused.
struct NotesRail: View {
    @ObservedObject var controller: PlanNotesController
    /// "Refine 2" for the checkpoint that consumed a note.
    let roundName: (Int) -> String?
    /// Renders only: a draft that grabbed focus would take it from the editor and close the
    /// selection toolbar the picture is meant to show beside it.
    var focusesDraft = true

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            NotesLane(controller: controller, geometry: controller.geometry, roundName: roundName, focusesDraft: focusesDraft)
            Divider()
            Text("Notes and your edits go to the next round when it starts.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("notes-rail")
    }

    private var header: some View {
        let pending = controller.pendingCount
        return HStack(spacing: 8) {
            Text("Notes").fontWeight(.semibold)
            if pending > 0 {
                Text("\(pending) for the next round").foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button { controller.annotate() } label: { Image(systemName: "plus") }
                .buttonStyle(.borderless)
                .help("Add a note about the whole plan (⌥⌘A)")
                .accessibilityLabel("Add Note")
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .frame(height: 38)
    }
}

/// The rail's body: the unplaced cards stacked at the top, then the aligned lane.
private struct NotesLane: View {
    @ObservedObject var controller: PlanNotesController
    @ObservedObject var geometry: NotesGeometry
    let roundName: (Int) -> String?
    let focusesDraft: Bool
    /// The lane's top edge in window coordinates (y up) — what turns a line's window Y into a
    /// card offset. Measured by an AppKit probe so both sides use the same coordinate system.
    @State private var laneTop: CGFloat?
    @State private var heights: [UUID: CGFloat] = [:]

    private static let gap: CGFloat = 8
    private static let inset: CGFloat = 10

    var body: some View {
        let cards = self.cards
        let placed = NotesRailModel.layout(cards, heights: heights, minGap: Self.gap)
        let stacked = cards.filter { placed[$0.id] == nil }
        VStack(spacing: 0) {
            if !stacked.isEmpty {
                VStack(spacing: Self.gap) {
                    ForEach(stacked) { card(for: $0) }
                }
                .padding(Self.inset)
            }
            // A fixed card width: offset cards in a bare ZStack sized the stack to their own
            // ideal widths, which ran past the column's edges and clipped the trash buttons.
            GeometryReader { lane in
                ZStack(alignment: .topLeading) {
                    ForEach(cards.filter { placed[$0.id] != nil }) { card in
                        self.card(for: card)
                            .frame(width: max(lane.size.width - 2 * Self.inset, 0))
                            .offset(x: Self.inset, y: placed[card.id] ?? 0)
                    }
                    if cards.isEmpty {
                        InspectorPlaceholder(title: "No Notes",
                                             message: "Select text in the plan to comment on it, ask about it, or ask for a change.")
                            .padding(.horizontal, Self.inset)
                    }
                }
                .frame(width: lane.size.width, height: lane.size.height, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(WindowTopProbe { top in if laneTop.map({ abs($0 - top) > 0.5 }) ?? true { laneTop = top } })
            .clipped()
        }
        .onPreferenceChange(CardHeightKey.self) { if $0 != heights { heights = $0 } }
        .animation(.easeOut(duration: 0.15), value: controller.draft?.id)
    }

    /// The draft rides along as a pending note so it is placed and ordered like one.
    private var cards: [NoteCardModel] {
        var notes = controller.notes
        if let draft = controller.draft {
            notes.append(TapeNote(note: PlanNote(id: draft.id, kind: draft.kind, note: draft.text, anchor: draft.anchor),
                                  consumedBy: nil))
        }
        let lineTop = controller.lineTop
        let located = controller.located
        return NotesRailModel.cards(notes: notes, located: { located[$0.id] }) { range in
            guard let laneTop, let lineTop, let y = lineTop(range) else { return nil }
            return laneTop - y
        }
    }

    @ViewBuilder
    private func card(for card: NoteCardModel) -> some View {
        Group {
            if let draft = controller.draft, draft.id == card.id {
                NoteDraftCard(controller: controller, quote: card.quote, focusOnAppear: focusesDraft)
            } else {
                let consumedBy = card.consumed ? controller.notes.first { $0.id == card.id }?.consumedBy : nil
                NoteCard(card: card, readBy: consumedBy.flatMap(roundName),
                         onRemove: card.consumed ? nil : { controller.remove(card.id) })
            }
        }
        .background(GeometryReader { geo in
            Color.clear.preference(key: CardHeightKey.self, value: [card.id: geo.size.height])
        })
    }
}

private struct CardHeightKey: PreferenceKey {
    static let defaultValue: [UUID: CGFloat] = [:]
    static func reduce(value: inout [UUID: CGFloat], nextValue: () -> [UUID: CGFloat]) {
        value.merge(nextValue()) { $1 }
    }
}

/// The quoted text with a bar in the highlight's colour, clipped to one line.
private struct QuoteLine: View {
    let quote: String
    let kind: NoteKind

    var body: some View {
        Text(quote.replacingOccurrences(of: "\n", with: " "))
            .font(.system(size: 11.5))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.leading, 7)
            .overlay(alignment: .leading) {
                Rectangle().fill(Color(nsColor: NoteStyle.highlight)).frame(width: 3)
            }
    }
}

private struct KindTag: View {
    let kind: NoteKind
    /// A Highlight is an empty comment; it says what the human did.
    var highlight = false

    /// The kind's symbol and word on a neutral capsule — the only place a card says its kind.
    var body: some View {
        Label(highlight ? "Highlight" : NoteStyle.label(kind), systemImage: highlight ? "highlighter" : NoteStyle.symbol(kind))
            .labelStyle(.titleAndIcon)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 1)
            .background(Color.primary.opacity(0.07), in: Capsule())
    }
}

private struct NoteCard: View {
    let card: NoteCardModel
    let readBy: String?
    let onRemove: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if card.detached {
                Label("Can't find this text any more", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if let quote = card.quote { QuoteLine(quote: quote, kind: card.kind) }
            if !card.note.isEmpty {
                Text(card.note)
                    .font(.system(size: 12))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            HStack(spacing: 6) {
                KindTag(kind: card.kind, highlight: card.kind == .comment && card.note.isEmpty)
                if let readBy { Text("Read by \(readBy)").font(.caption).foregroundStyle(.tertiary) }
                Spacer(minLength: 0)
                if let onRemove {
                    Button(action: onRemove) { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.tertiary)
                        .help("Remove this note")
                        .accessibilityLabel("Remove Note")
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quinary, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(.separator))
        .opacity(card.consumed ? 0.5 : 1)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        var parts = [NoteStyle.label(card.kind)]
        if let quote = card.quote { parts.append("on “\(quote)”") }
        if card.detached { parts.append("can't find this text any more") }
        if !card.note.isEmpty { parts.append(card.note) }
        if let readBy { parts.append("read by \(readBy)") }
        return parts.joined(separator: ", ")
    }
}

/// The note being written: its field focused, its kind switchable, sent with ⌘↩ (or when focus
/// leaves with something written), dropped with Esc. Never a modal (spec §2: panels, not sheets,
/// for repeated input).
private struct NoteDraftCard: View {
    @ObservedObject var controller: PlanNotesController
    let quote: String?
    let focusOnAppear: Bool
    @FocusState private var focused: Bool

    var body: some View {
        let kind = controller.draft?.kind ?? .comment
        let text = controller.draft?.text ?? ""
        VStack(alignment: .leading, spacing: 7) {
            if let quote { QuoteLine(quote: quote, kind: kind) }
            TextField(NoteStyle.placeholder(kind), text: Binding(get: { controller.draft?.text ?? "" },
                                                                 set: { controller.draft?.text = $0 }),
                      axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .lineLimit(2...8)
                .focused($focused)
                .padding(.horizontal, 7)
                .padding(.vertical, 5)
                .background(Color.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.accentColor.opacity(0.7)))
                .accessibilityIdentifier("note-draft-field")
            HStack(spacing: 6) {
                // A pop-up, not the mockup's segments: five segments need more than the
                // inspector's 300 pt minimum and pushed the card past the column's edge.
                Picker("Kind", selection: Binding(get: { controller.draft?.kind ?? .comment },
                                                  set: { controller.draft?.kind = $0 })) {
                    ForEach(NoteStyle.kinds, id: \.self) { Text(NoteStyle.label($0)).tag($0) }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
                .accessibilityIdentifier("note-draft-kind")
                Spacer(minLength: 0)
                Button("Cancel") { controller.cancelDraft() }
                    .keyboardShortcut(.cancelAction)
                Button("Add Note") { controller.commitDraft() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(!NotesRailModel.draftCommits(kind: kind, text: text))
                    .accessibilityIdentifier("note-draft-add")
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.quinary, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.accentColor.opacity(0.6)))
        .shadow(color: Color.accentColor.opacity(0.25), radius: 3)
        .onAppear { if focusOnAppear { DispatchQueue.main.async { focused = true } } }
        // Blur commits (or drops an empty draft) — clicking back into the plan to select the
        // next passage must not leave this one hanging unsent.
        .onChange(of: focused) { was, now in if was && !now { controller.commitDraft() } }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("note-draft")
    }
}

/// Reports its view's top edge in window coordinates (y up) whenever it lays out or moves
/// window — the rail's half of lining cards up with the editor's lines, measured the way the
/// editor measures its own (`NSView.convert(_:to: nil)`), so the two can't disagree about
/// where the window's origin is.
private struct WindowTopProbe: NSViewRepresentable {
    let onChange: (CGFloat) -> Void

    func makeNSView(context: Context) -> ProbeView { ProbeView() }
    func updateNSView(_ view: ProbeView, context: Context) {
        view.onChange = onChange
        view.report()
    }

    final class ProbeView: NSView {
        var onChange: ((CGFloat) -> Void)?
        private var last: CGFloat?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); report() }
        override func layout() { super.layout(); report() }

        func report() {
            guard window != nil else { return }
            let top = convert(bounds, to: nil).maxY
            guard top != last else { return }
            last = top
            // Async: this runs inside a layout or view update, where SwiftUI state can't change.
            let onChange = onChange
            DispatchQueue.main.async { onChange?(top) }
        }
    }
}
