import FleetKit
import MarkdownUI
import SwiftUI

/// The whole plan as one scroll (spec §4.8), split with `PlanBlocks.split` — the same split the
/// Mac used to locate notes, so a note's `blockIndex` names this block.
///
/// Notes (Phase 2): when `PlanReaderStyle.notesAllowed`, selected prose gains **Note…**, each
/// block a "Passage actions" menu, the plan a footer button, and a pending note a **Delete**.
/// Otherwise the reader is exactly Phase 1's — an older Mac never sees an `intake.*` command.
struct PlanReaderScreen: View {
    let intake: UUID
    let checkpoint: Int?
    let startBlock: Int?
    @State var changes: Bool
    let flightControl: FlightControlModel
    @State private var plan: WireIntakePlan?
    /// What the screen is showing: the `changes` value of the reply that produced `plan`, so the
    /// diff overlay never draws over a plan fetched without a diff.
    @State private var loadedChanges: Bool?
    @State private var failed = false
    @State private var requests = LatestRequest()
    @State private var openBlock: BlockNotes?
    /// The note sheet's item. Its `id` is the note's wire id, minted here, once.
    @State private var draft: NoteDraft?
    @State private var outbox = NoteOutbox()
    /// The note whose Delete / Discard is awaiting confirmation. The phone has no Undo (the Mac
    /// has), so dropping the maintainer's words always asks first.
    @State private var confirmingDelete: UUID?
    @State private var confirmingDiscard: UUID?

    private var commands: IntakeCommandModel { flightControl.commands(for: intake) }
    private var detailModel: IntakeDetailModel { flightControl.detailModel(for: intake) }
    private var notesAllowed: Bool { PlanReaderStyle.notesAllowed(detail: detailModel.detail, checkpoint: checkpoint) }

    /// The sheet's item: a block, not one note, so every note pinned to it is reachable.
    struct BlockNotes: Identifiable {
        let id: Int
    }

    init(intake: UUID, checkpoint: Int?, startBlock: Int?, changes: Bool, flightControl: FlightControlModel) {
        self.intake = intake; self.checkpoint = checkpoint; self.startBlock = startBlock
        self._changes = State(initialValue: changes); self.flightControl = flightControl
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if failed {
                    VStack(spacing: 12) {
                        Text(changes ? "Couldn't load changes." : "Couldn't load the plan.")
                            .font(.subheadline).foregroundStyle(.secondary)
                        Button("Retry") { load() }.font(.subheadline)
                    }
                    .padding(40)
                } else if let plan {
                    let showDiff = changes && loadedChanges == true
                    let blocks = PlanBlocks.split(plan.markdown).blocks
                    let added = Set(showDiff ? (plan.added ?? []) : [])
                    let allNotes = plan.notes + outbox.sentNotes
                    LazyVStack(alignment: .leading, spacing: 10) {
                        removed(after: nil, plan, show: showDiff)
                        ForEach(blocks, id: \.index) { block in
                            let notes = allNotes.filter { $0.blockIndex == block.index }
                            let unsent = outbox.unsent.filter { $0.target.block == block.index }
                            HStack(alignment: .top, spacing: 8) {
                                VStack(alignment: .leading, spacing: 6) {
                                    ForEach(Array(PlanReaderStyle.segments(of: block.text).enumerated()), id: \.offset) { _, segment in
                                        segmentView(segment, block: block.index, plan: plan)
                                    }
                                    ForEach(unsent) { d in unsentCard(d) }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                if !notes.isEmpty {
                                    notesButton(count: notes.count) { openBlock = BlockNotes(id: block.index) }
                                }
                                if notesAllowed {
                                    passageMenu(block: block.index, noteCount: notes.count, plan: plan)
                                }
                            }
                            .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(RoundedRectangle(cornerRadius: 4).fill(
                                    added.contains(block.index) ? Color.green.opacity(0.12)
                                    : notes.contains { !$0.consumed } || !unsent.isEmpty ? Color.yellow.opacity(0.14)
                                    : notes.isEmpty ? Color.clear : Color.yellow.opacity(0.06)))
                                .id(block.index)
                            removed(after: block.index, plan, show: showDiff)
                        }
                        let detached = allNotes.filter { $0.blockIndex == nil && !$0.consumed }
                        let unsentWide = outbox.unsent.filter { $0.target.block == nil }
                        if !detached.isEmpty || !unsentWide.isEmpty {
                            Divider()
                            Text("Notes not pinned to a passage").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                            ForEach(detached, id: \.id) { n in noteCard(n) }
                            ForEach(unsentWide) { d in unsentCard(d) }
                        }
                        if notesAllowed {
                            Divider()
                            Button { draft = NoteDraft(target: NoteDraftTarget(block: nil, quote: nil), showing: plan.checkpoint) } label: {
                                Label { Text("Add a note to the whole plan").font(.subheadline) } icon: { Image(systemName: "text.bubble") }
                                    .frame(minHeight: 44)
                            }
                        }
                    }
                    .padding(16)
                    .task { if let startBlock { proxy.scrollTo(startBlock, anchor: .top) } }
                } else {
                    ProgressView().padding(40)
                }
            }
        }
        .navigationTitle(plan?.roundName ?? "Plan")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Toggle(isOn: $changes) { Text("Changes") }.toggleStyle(.button).font(.footnote)
                    .accessibilityLabel("Show changes since the previous round")
            }
        }
        .safeAreaInset(edge: .bottom) { if notesAllowed { messageRow } }
        .sheet(item: $openBlock) { item in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    messageRow
                    ForEach(((plan?.notes ?? []) + outbox.sentNotes).filter { $0.blockIndex == item.id }, id: \.id) { n in noteCard(n) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
            .presentationDetents([.medium])
        }
        .sheet(item: $draft) { d in
            NoteSheet(draft: d) { submit($0) }
        }
        .task(id: changes) { load() }
        .intakePresence(id: intake, model: flightControl.detailModel(for: intake), flightControl: flightControl)
    }

    /// The way into a block's notes. A button beside the text rather than a tap on it: a tap
    /// gesture on the block competes with the press that starts a text selection, and selection
    /// is what a reader of a plan needs. A real `Button`, so VoiceOver reaches it as one.
    private func notesButton(count: Int, open: @escaping () -> Void) -> some View {
        Button(action: open) {
            Text(PlanReaderStyle.notesLabel(count: count))
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Capsule().fill(Color.yellow.opacity(0.25)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(PlanReaderStyle.notesLabel(count: count))
    }

    /// A block's actions. A menu rather than a tap on the block, for the same reason as the
    /// notes button: a tap would compete with the press that starts a selection.
    private func passageMenu(block: Int, noteCount: Int, plan: WireIntakePlan) -> some View {
        Menu {
            Button { draft = NoteDraft(target: NoteDraftTarget(block: block, quote: nil), showing: plan.checkpoint) } label: {
                Label("Add note to this passage", systemImage: "text.bubble")
            }
            if noteCount > 0 {
                Button { openBlock = BlockNotes(id: block) } label: {
                    Label("Show \(PlanReaderStyle.notesLabel(count: noteCount))", systemImage: "note.text")
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle").font(.body).foregroundStyle(.secondary)
                .frame(minWidth: 44, minHeight: 44)
        }
        .accessibilityLabel("Passage actions")
    }

    /// The last command's failure, in words, dismissable — as on the intake screen.
    @ViewBuilder private var messageRow: some View {
        if let message = commands.message {
            HStack(alignment: .firstTextBaseline) {
                Text(message).font(.caption).foregroundStyle(.orange)
                Spacer()
                Button { commands.clearMessage() } label: {
                    Image(systemName: "xmark").font(.caption).frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityLabel("Dismiss")
            }
            .padding(.horizontal, 16)
            .background(.bar)
        }
    }

    /// Prose is selectable attributed text (the timeline's own renderer); code, tables, lists
    /// and quotes stay MarkdownUI, which cannot be an attributed run, with system selection on.
    /// **Note…** quotes the selection as rendered; the Mac finds it in the block's source.
    @ViewBuilder private func segmentView(_ segment: TimelineSegment, block: Int, plan: WireIntakePlan) -> some View {
        switch segment {
        case .prose(let text):
            SelectableProseView(markdown: text, actions: notesAllowed ? [
                ProseAction(title: "Note…", systemImage: "text.bubble") { quote in
                    draft = NoteDraft(target: NoteDraftTarget(block: block, quote: quote), showing: plan.checkpoint)
                },
            ] : [])
        case .code(let language, let text):
            Markdown(TimelineSegment.fenced(language: language, text))
                .markdownTheme(TimelineMarkdown.theme).textSelection(.enabled)
        case .richBlock(let text):
            Markdown(text).markdownTheme(TimelineMarkdown.theme).textSelection(.enabled)
        }
    }

    @ViewBuilder private func removed(after index: Int?, _ plan: WireIntakePlan, show: Bool) -> some View {
        if show {
            ForEach(Array((plan.removed ?? []).filter { $0.after == index }.enumerated()), id: \.offset) { _, r in
                Text(r.text).font(.subheadline).strikethrough().foregroundStyle(.secondary)
                    .padding(.horizontal, 6).background(RoundedRectangle(cornerRadius: 4).fill(Color.red.opacity(0.08)))
                    .accessibilityLabel("Removed: \(r.text)")
            }
        }
    }

    private func noteCard(_ n: WireNote) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(OutlineStyle.kindName(n.kind, text: n.text)).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            if let q = n.quote { Text("“\(q)”").font(.subheadline).italic().foregroundStyle(.secondary) }
            if !n.text.isEmpty { Text(n.text).font(.body) }
            if n.consumed { Text("Read by a round").font(.caption).foregroundStyle(.secondary) }
            if !n.consumed && notesAllowed {
                let deleting = commands.inFlight.contains(.removeNote(n.id))
                Button(role: .destructive) { confirmingDelete = n.id } label: {
                    Text(deleting ? "Deleting…" : "Delete").font(.subheadline).frame(minHeight: 44)
                }
                .disabled(deleting)
            }
        }
        .opacity(n.consumed ? 0.7 : 1)
        // On the card, not the screen: a card also lives in the notes sheet, and a dialog
        // attached under a presented sheet never shows.
        .confirmationDialog("Delete this note?", isPresented: confirming($confirmingDelete, n.id), titleVisibility: .visible) {
            Button("Delete Note", role: .destructive) { remove(n.id) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The next round won't see it.").font(.subheadline)
        }
    }

    /// A dialog's `isPresented` for one note out of the id awaiting confirmation.
    private func confirming(_ state: Binding<UUID?>, _ id: UUID) -> Binding<Bool> {
        Binding(get: { state.wrappedValue == id }, set: { if !$0 { state.wrappedValue = nil } })
    }

    /// A note this reader composed that the Mac has not acked. In flight it says so, plainly;
    /// failed (the reason is in `messageRow`), it keeps its words and offers the retry — the same
    /// note id, and after a timeout the same token, so the Mac cannot take it twice.
    private func unsentCard(_ d: NoteDraft) -> some View {
        let sending = commands.inFlight.contains(.note(d.id))
        return VStack(alignment: .leading, spacing: 6) {
            Text(OutlineStyle.kindName(NoteComposer.wire(kind: d.kind).kind, text: d.text))
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            if let q = d.target.quote { Text("“\(q)”").font(.subheadline).italic().foregroundStyle(.secondary) }
            if !d.text.isEmpty { Text(d.text).font(.body) }
            if sending {
                Text("Not yet sent").font(.caption).foregroundStyle(.secondary)
            } else {
                HStack(spacing: 16) {
                    Text("Not sent").font(.caption).foregroundStyle(.secondary)
                    Button { submit(d) } label: { Text("Retry").font(.subheadline).frame(minHeight: 44) }
                    Button(role: .destructive) { confirmingDiscard = d.id } label: {
                        Text("Discard").font(.subheadline).frame(minHeight: 44)
                    }
                }
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(.secondarySystemBackground)))
        .confirmationDialog("Discard this note?", isPresented: confirming($confirmingDiscard, d.id), titleVisibility: .visible) {
            Button("Discard", role: .destructive) { outbox.remove(d.id) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It hasn't reached your Mac, and its words will be lost.").font(.subheadline)
        }
    }

    /// Send a composed note. It is listed as unsent first, so the tap changes the screen before
    /// any answer; the ack re-requests the head, which lists it (or, still queued on the Mac,
    /// the outbox keeps showing it).
    private func submit(_ d: NoteDraft) {
        draft = nil
        outbox.submit(d)
        let kind = NoteComposer.wire(kind: d.kind).kind
        commands.send(.note(d.id), command: {
            .intakeNote(id: intake, token: $0, noteID: d.id, kind: kind, text: d.text,
                        checkpoint: d.checkpoint, block: d.target.block, quote: d.target.quote)
        }, onAck: {
            outbox.acked(d.id)
            reloadHead()
        })
    }

    private func remove(_ noteID: UUID) {
        commands.send(.removeNote(noteID), command: {
            .intakeRemoveNote(id: intake, token: $0, noteID: noteID)
        }, onAck: {
            outbox.remove(noteID)
            reloadHead()
        }, onFailure: { error in
            outbox.removeFailed(noteID, error: error)
        })
    }

    /// The head contract: after a note is added or removed, re-request the head with
    /// `checkpoint: nil` (never the cache), and the detail, whose note count moved too. Notes
    /// are only offered at the head, so this is the plan the reader was showing.
    private func reloadHead() {
        load(checkpoint: nil, refreshing: true)
        detailModel.refresh()
    }

    private func load() { load(checkpoint: checkpoint, refreshing: false) }

    /// `refreshing`: a re-request behind a plan already on screen, whose failure leaves that plan
    /// (and the outbox's notes) showing rather than replacing it with "Couldn't load".
    private func load(checkpoint: Int?, refreshing: Bool) {
        let token = requests.begin()
        let asked = changes
        if !refreshing { failed = false }
        flightControl.plan(intake, checkpoint: checkpoint, changes: asked) { result in
            guard requests.accepts(token) else { return }
            switch result {
            case .success(let p): plan = p; loadedChanges = asked; outbox.reconcile(with: p.notes)
            case .failure: if !refreshing || plan == nil { failed = true }
            }
        }
    }
}

/// What the plan reader draws for a block, decided apart from SwiftUI so it can be tested.
/// Follows `TimelineStyle`: the timeline's segmenter is the one place that knows what an
/// attributed run can express.
enum PlanReaderStyle {
    /// A block's segments: `.prose` becomes selectable text, the rest stays MarkdownUI.
    static func segments(of blockText: String) -> [TimelineSegment] {
        TimelineSegmenter.segments(of: blockText)
    }

    /// Whether the reader offers notes: the intake must take them (`NoteComposer.notesAllowed`)
    /// and the reader must be on the head (`checkpoint == nil`, which is how every route opens
    /// the head). After a note lands the reader re-requests the head (the Phase-1 cache
    /// contract), which on an older round would swap its text for the current plan under the maintainer's
    /// thumb; and a note is for the next round, which refines the head.
    static func notesAllowed(detail: WireIntakeDetail?, checkpoint: Int?) -> Bool {
        checkpoint == nil && NoteComposer.notesAllowed(detail: detail)
    }

    /// The notes button's text and accessibility label.
    static func notesLabel(count: Int) -> String { "\(count) note\(count == 1 ? "" : "s")" }
}
