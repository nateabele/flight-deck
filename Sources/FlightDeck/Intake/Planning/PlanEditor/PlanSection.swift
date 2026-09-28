import IntakeKit
import SwiftUI

/// The plan part of an intake (spec §7): Plan · Diff vs Previous · Change set, with the plan
/// editable in place as live-preview Markdown on the head checkpoint and read-only on any
/// earlier one.
///
/// Inputs are injected: `loadFile(checkpointID, relativePath)` reads out
/// of `checkpoints/<id>/`, and `onSend` queues a `TapeCommand` (the caller binds the intake).
/// `selection` is the checkpoint the human picked on the timeline, nil to follow the head.
struct PlanSection: View {
    let intakeID: UUID
    let tape: Tape
    let loadFile: (Int, String) -> Data?
    let onSend: (TapeCommand) -> Void
    @Binding var selection: Int?
    var initialMode: ShapingModel.ViewerMode = .plan
    var editHooks = PlanEditHooks()
    /// Highlight-and-annotate (spec §7.3); nil leaves the plan unannotatable.
    var notes: PlanNotesController?
    /// The convergence churn lane for the head plan (spec §8.2) — see `churnLane(_:)`.
    var churn: ChurnLaneInput?
    /// A request to show one round's Diff vs Previous at a section — see `focus(_:)`.
    var focus: PlanFocus?
    /// Every checkpoint read-only, the head included — see `readOnly(_:)`.
    var readOnly = false

    init(intakeID: UUID, tape: Tape, loadFile: @escaping (Int, String) -> Data?, onSend: @escaping (TapeCommand) -> Void,
         selection: Binding<Int?> = .constant(nil), mode: ShapingModel.ViewerMode = .plan, notes: PlanNotesController? = nil) {
        self.intakeID = intakeID
        self.tape = tape
        self.loadFile = loadFile
        self.onSend = onSend
        _selection = selection
        initialMode = mode
        self.notes = notes
    }

    var body: some View {
        // Keyed on the intake so switching intakes starts a fresh editor, instead of offering
        // the other intake's plan as "a new round landed".
        PlanSectionBody(tape: tape, loadFile: loadFile, onSend: onSend, selection: $selection, mode: initialMode,
                        hooks: editHooks, notes: notes, churn: churn, focus: focus, readOnly: readOnly)
            .id(intakeID)
    }

    /// Where the edit layer reports to the intake (`PlanEditHooks`).
    func editHooks(_ hooks: PlanEditHooks) -> PlanSection {
        var copy = self
        copy.editHooks = hooks
        return copy
    }

    /// Shows the churn lane beside the head plan's headings.
    func churnLane(_ input: ChurnLaneInput?) -> PlanSection {
        var view = self
        view.churn = input
        return view
    }

    /// Switches to Diff vs Previous and scrolls the page to `focus.section` whenever `focus` changes —
    /// how a heatmap cell shows that round's change to that section (spec §8.3). The caller
    /// selects the round itself, through `selection`.
    func focus(_ focus: PlanFocus?) -> PlanSection {
        var view = self
        view.focus = focus
        return view
    }

    /// The final plan (review and after): the head is shown like any other checkpoint, with no
    /// "Viewing … · Go to latest" bar, since it IS the latest and there is nowhere to go.
    func readOnly(_ readOnly: Bool) -> PlanSection {
        var view = self
        view.readOnly = readOnly
        return view
    }

    /// The unified diff cut at its hunks, each named by the heading it changes in `plan` (the
    /// newer side) — so Diff vs Previous can scroll to a section. Text before the first hunk,
    /// or a message instead of a diff, is one unnamed chunk.
    static func diffChunks(_ diff: String, plan: String) -> [DiffChunk] {
        let planLines = plan.components(separatedBy: "\n")
        var headingAt: [String?] = []
        var current: String?
        for line in planLines {
            if line.hasPrefix("#") { current = line.trimmingCharacters(in: .whitespaces) }
            headingAt.append(current)
        }
        var chunks: [DiffChunk] = []
        for line in diff.components(separatedBy: "\n") {
            if line.hasPrefix("@@") || chunks.isEmpty {
                chunks.append(DiffChunk(id: chunks.count, section: nil, lines: [line],
                                        newLine: line.hasPrefix("@@") ? Self.newStart(line) : 0))
                continue
            }
            var chunk = chunks.removeLast()
            chunk.lines.append(line)
            if chunk.section == nil, line.hasPrefix("+") || line.hasPrefix("-") {
                let at = line.hasPrefix("-") ? chunk.newLine - 1 : chunk.newLine
                chunk.section = headingAt.isEmpty ? nil : headingAt[max(0, min(at, headingAt.count - 1))]
            }
            if line.hasPrefix(" ") || line.hasPrefix("+") { chunk.newLine += 1 }
            chunks.append(chunk)
        }
        return chunks
    }

    /// The 0-based index of the first new-side line a hunk header ("@@ -a,b +c,d @@") covers.
    private static func newStart(_ header: String) -> Int {
        guard let plus = header.split(separator: " ").first(where: { $0.hasPrefix("+") }) else { return 0 }
        let parts = plus.dropFirst().split(separator: ",")
        let start = Int(parts.first ?? "") ?? 1
        let count = parts.count > 1 ? Int(parts[1]) ?? 1 : 1
        // A zero-length side names the line BEFORE the change (unified-diff convention).
        return count == 0 ? start : max(0, start - 1)
    }

    /// What the plan tab shows for a checkpoint: the effective plan (`plan.user.md` if the
    /// human edited it, else what the round generated) — the same layer the next round reads.
    /// `PlanLayers.effectivePlan` takes a directory; this is its rule over `loadFile`.
    static func effectivePlan(checkpoint: Int, tape: Tape, loadFile: (Int, String) -> Data?) -> String? {
        if let edited = loadFile(checkpoint, PlanLayers.userName) { return PlanLayers.readPlan(edited) }
        return ShapingModel.planText(checkpoint: checkpoint, in: tape, loadFile: loadFile)
    }

    /// The checkpoint edits go to: the newest one with a plan (`TapeStore.headPlanCheckpoint`'s
    /// rule) — encode and polish checkpoints carry a change set, not a plan, so "the head" alone
    /// would leave nothing editable once encoding starts.
    static func planHead(tape: Tape, loadFile: (Int, String) -> Data?) -> Int? {
        tape.checkpoints.last { ShapingModel.planText(checkpoint: $0.id, in: tape, loadFile: loadFile) != nil }?.id
    }

    /// The agents' round-to-round changes, in a neutral treatment (spec §7.2): green and red
    /// belong to the human's own edits in the plan, and a diff in the same colours would read
    /// as "you changed this". Added lines are full-strength on a grey wash, removed lines
    /// quieter, hunk headers quieter still. A single `AttributedString` rather than one
    /// `Text` per line so a long diff stays one text view (and one selection).
    static func coloredDiff(_ diff: String) -> AttributedString {
        var out = AttributedString()
        for (i, line) in diff.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            var piece = AttributedString((i == 0 ? "" : "\n") + line)
            if line.hasPrefix("+") {
                piece.foregroundColor = .primary
                piece.backgroundColor = Color.primary.opacity(0.08)
            } else if line.hasPrefix("-") {
                piece.foregroundColor = .secondary
            } else if line.hasPrefix("@@") {
                piece.foregroundColor = Color.secondary.opacity(0.7)
            }
            out += piece
        }
        return out
    }

    /// One hunk of Diff vs Previous and the section it changes.
    struct DiffChunk: Equatable, Identifiable {
        let id: Int
        var section: String?
        var lines: [String]
        /// Where the walk through the hunk has reached on the new side (a parsing cursor).
        var newLine: Int
        var text: String { lines.joined(separator: "\n") }
    }

    /// The page's `.id` for Diff vs Previous's hunk `chunk` — a heatmap cell's jump target.
    static func diffAnchor(_ chunk: Int) -> String { "plan-diff-\(chunk)" }

    /// "Refine 2" — the full name for the read-only bar, where there is room for it.
    static func checkpointName(_ checkpoint: Checkpoint) -> String {
        switch checkpoint.stage {
        case .draft: "Drafts"
        case .synthesis: "Synthesis"
        case .refine: "Refine \(checkpoint.round)"
        case .encode: "Encode"
        case .polish: "Polish \(checkpoint.round)"
        case .freshEyes: "Fresh eyes"
        case .dedup: "Dedup"
        }
    }
}

struct PlanSectionBody: View {
    let tape: Tape
    let loadFile: (Int, String) -> Data?
    let onSend: (TapeCommand) -> Void
    @Binding var selection: Int?
    @State private var mode: ShapingModel.ViewerMode

    /// The checkpoint whose plan the editor holds, and whether it may be edited — both fixed
    /// when the text is loaded, so a round landing mid-edit neither retargets the edit nor
    /// flips the editor read-only under the caret.
    @State private var shown: Loaded?
    @State private var text = ""
    @State private var incoming: Loaded?
    /// `incoming` is the human's own choice of round, not a head that landed — see `reload`.
    @State private var incomingIsNavigation = false
    /// The selection the last reload saw, to tell a round chosen on the timeline apart from
    /// a new head arriving while the view follows the head.
    @State private var loadedSelection: Int??
    /// Where commits go, and the edits sent but maybe not yet applied by the runner
    /// (`PlanEditRouter.sent`): reloading the checkpoint from disk before then would offer the
    /// pre-edit plan back as if it were news. The intake's own (`PlanEditHooks.router`) when
    /// the pane hands one in, so an intake switch doesn't forget what is stuck or sent.
    @State private var ownRouter = PlanEditRouter()
    private var router: PlanEditRouter { hooks.router ?? ownRouter }
    /// Revert all acts through the editor, so it is one undoable change.
    @State private var editor = PlanEditorHandle()
    @State private var confirmingRevertAll = false
    @State private var otherText = AttributedString()
    @State private var diffChunks: [PlanSection.DiffChunk] = []
    /// The chunk a heatmap cell asked Diff vs Previous to scroll to, tagged with the request's
    /// `seq` so a repeat of the same cell still scrolls.
    @State private var diffTarget: [Int]?
    @State private var pendingFocus: PlanFocus?
    @State private var message: String?
    let hooks: PlanEditHooks
    /// Each checkpoint's generated plan — the edit layer's base. Written once per checkpoint
    /// and never modified, so it is read once.
    @State private var generated: [Int: String] = [:]
    /// "Your edits are kept…", up in this section since it first showed (`PlanEditHooks`).
    @State private var showKeptNote = false
    let notes: PlanNotesController?
    let churn: ChurnLaneInput?
    let focus: PlanFocus?
    let readOnly: Bool
    @Environment(\.pageJump) private var pageJump
    @Environment(\.pageObscuredTop) private var pageObscuredTop

    struct Loaded: Equatable {
        var checkpoint: Int
        var text: String
        var editable: Bool
    }

    init(tape: Tape, loadFile: @escaping (Int, String) -> Data?, onSend: @escaping (TapeCommand) -> Void,
         selection: Binding<Int?>, mode: ShapingModel.ViewerMode, hooks: PlanEditHooks,
         notes: PlanNotesController? = nil, churn: ChurnLaneInput? = nil, focus: PlanFocus? = nil, readOnly: Bool = false) {
        self.readOnly = readOnly
        self.churn = churn
        self.focus = focus
        self.tape = tape
        self.loadFile = loadFile
        self.onSend = onSend
        _selection = selection
        _mode = State(initialValue: mode)
        self.hooks = hooks
        self.notes = notes
    }

    var body: some View {
        let key = ShapingModel.viewerKey(selected: selection, mode: mode, tape: tape)
        let hunks = userHunks
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Picker("View", selection: $mode) {
                    Text("Plan").tag(ShapingModel.ViewerMode.plan)
                    Text("Diff vs Previous").tag(ShapingModel.ViewerMode.diff)
                    Text("Change set").tag(ShapingModel.ViewerMode.changeSet)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                if mode == .plan, let chip = EditLayer.chip(hunks) { editChip(chip) }
                Spacer(minLength: 0)
            }
            if mode == .plan, showKeptNote, !hunks.isEmpty { keptNote }

            if mode == .plan, let shown, !shown.editable, !readOnly {
                pastBar(shown.checkpoint)
            }
            // As tall as what it shows: the plan, the diff and the change set are all part of
            // the page, which does the scrolling (`PlanEditorContainer`).
            content
                .frame(minHeight: PlanEditorContainer.minimumTextHeight, alignment: .topLeading)
                .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
        }
        .accessibilityIdentifier("plan-viewer")
        .onChange(of: key, initial: true) { _, key in reload(key) }
        .onChange(of: !hunks.isEmpty, initial: true) { _, edited in
            // Once per plan: the first time it carries edits, and never again for this intake.
            guard edited, !hooks.noteShown, !showKeptNote else { return }
            showKeptNote = true
            hooks.onNoteShown()
        }
        // The next-round tooltip's "3 edits" is the chip's count, taken only on the head: a
        // past round's edits are not what the next round is sent.
        .onChange(of: shown?.editable == true ? hunks.count : nil, initial: true) { _, count in
            if let count { notes?.setEdits(count) }
        }
        .onChange(of: tape, initial: true) { _, tape in bindRouter(tape) }
        .onChange(of: focus, initial: true) { _, focus in
            guard let focus else { return }
            pendingFocus = focus
            if mode == .diff { reload(ShapingModel.viewerKey(selected: selection, mode: mode, tape: tape)) } else { mode = .diff }
        }
    }

    // MARK: - Edit layer

    /// The human's edits on the checkpoint shown, as of the last commit (the editor's own
    /// marks follow every keystroke; the chip catches up within `EditPolicy.idle`).
    private var userHunks: [PlanHunk] {
        guard let shown, let base = generated[shown.checkpoint] else { return [] }
        return PlanLayers.userDiff(generated: base, edited: text)
    }

    /// "3 edits by you · Revert all" (spec §7.2), green like the edits it counts.
    private func editChip(_ chip: String) -> some View {
        HStack(spacing: 5) {
            Text(chip)
            if shown?.editable == true {
                Text("·").foregroundStyle(.secondary)
                Button("Revert all") { confirmingRevertAll = true }
                    .buttonStyle(.plain)
                    .fontWeight(.semibold)
                    .accessibilityIdentifier("plan-edit-revert-all")
                    .popover(isPresented: $confirmingRevertAll, arrowEdge: .bottom) {
                        RevertAllConfirmation(prompt: EditLayer.revertAllPrompt(userHunks.count),
                                              onRevert: { confirmingRevertAll = false; editor.revertAll() },
                                              onCancel: { confirmingRevertAll = false })
                    }
            }
        }
        .font(.caption)
        .foregroundStyle(Color(nsColor: EditLayer.barColor))
        .padding(.horizontal, 9)
        .frame(height: 22)
        .background(Color(nsColor: EditLayer.barColor).opacity(0.12), in: Capsule())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("plan-edit-chip")
    }

    private var keptNote: some View {
        HStack(spacing: 8) {
            Image(systemName: "pin").foregroundStyle(.secondary)
            Text(EditLayer.keptNote)
            HStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 1.5).fill(Color(nsColor: EditLayer.barColor)).frame(width: 3, height: 11)
                Text("you").foregroundStyle(.tertiary)
            }
            .padding(.leading, 4)
            Spacer(minLength: 0)
            Button { showKeptNote = false } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .help("Hide")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 6))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("plan-edit-kept-note")
    }

    /// Sends an edit — for the checkpoint it was typed on, or merged onto a newer head
    /// (`PlanEditRouter`).
    private func commitEdit(_ markdown: String, to loaded: Loaded) {
        bindRouter(tape)
        router.commit(markdown, typedOn: loaded.checkpoint, loaded: loaded.text, editable: loaded.editable)
    }

    /// Points the router at this intake: the live tape (the service's, else the latest this
    /// view was handed), where to send, and how a merged plan reaches the editor.
    private func bindRouter(_ latest: Tape) {
        let live = hooks.liveTape
        router.env = PlanEditRouter.Env(tape: { live?() ?? latest }, loadFile: loadFile, send: onSend,
                                        onConflict: hooks.onConflict,
                                        deliver: { checkpoint, plan in deliver(plan, to: checkpoint) },
                                        runner: hooks.runner)
    }

    /// A merge's plan for `checkpoint`: offered to the editor as `incoming` — never written
    /// into `text`, which is a load and would replace whatever the human is typing. The
    /// editor's own rule (`EditPolicy`) then shows it at once or holds it behind the banner.
    private func deliver(_ plan: String, to checkpoint: Int) {
        if let next = PlanSectionBody.offer(plan, for: checkpoint, shown: shown, incoming: incoming) {
            incomingIsNavigation = false
            incoming = next
        }
    }

    /// What `incoming` becomes when a merge wrote `plan` for `checkpoint`: the new text for a
    /// head waiting behind the banner, or for the head on screen; nil when neither shows it
    /// (the human is on an earlier round — the head's reload picks up the merge).
    static func offer(_ plan: String, for checkpoint: Int, shown: Loaded?, incoming: Loaded?) -> Loaded? {
        if var waiting = incoming, waiting.checkpoint == checkpoint {
            waiting.text = plan
            return waiting
        }
        guard let shown, shown.checkpoint == checkpoint else { return nil }
        return Loaded(checkpoint: checkpoint, text: plan, editable: shown.editable)
    }

    @ViewBuilder private var content: some View {
        if let message {
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(8)
        } else if mode == .plan, let shown {
            PlanTextView(text: $text, editable: shown.editable,
                         onCommit: { markdown in commitEdit(markdown, to: shown) },
                         incoming: incoming?.text,
                         onShowIncoming: {
                             guard let incoming else { return }
                             self.shown = incoming
                             text = incoming.text
                             self.incoming = nil
                             incomingIsNavigation = false
                         },
                         incomingIsNavigation: incomingIsNavigation)
                .editLayer(generated: generated[shown.checkpoint])
                .handle(editor)
                .churnLane(shown.editable ? churn : nil)
                .annotating(notes)
                .onChange(of: shown.checkpoint, initial: true) { _, checkpoint in notes?.checkpoint = checkpoint }
        } else if mode == .diff {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(diffChunks) { chunk in
                    Text(PlanSection.coloredDiff(chunk.text))
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        // The jump's target: a point at the hunk's top, whatever the hunk's height.
                        .background(alignment: .top) {
                            Color.clear.frame(height: 1).id(PlanSection.diffAnchor(chunk.id))
                        }
                }
            }
            .padding(8)
            .onChange(of: diffTarget, initial: true) { _, target in
                if let chunk = target?.first { pageJump?.scroll(PlanSection.diffAnchor(chunk), pageObscuredTop) }
            }
        } else {
            Text(otherText)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(8)
        }
    }

    private func pastBar(_ checkpoint: Int) -> some View {
        let name = tape.checkpoints.first { $0.id == checkpoint }.map(PlanSection.checkpointName) ?? "an earlier round"
        return HStack(spacing: 8) {
            Image(systemName: "clock.arrow.circlepath").foregroundStyle(.secondary)
            Text("Viewing \(name)").font(.callout)
            Text("·").foregroundStyle(.tertiary)
            Button("Go to latest") { selection = nil }
                .buttonStyle(.link)
                .accessibilityIdentifier("plan-go-to-latest")
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("plan-past-bar")
    }

    private func reload(_ key: ShapingModel.ViewerKey) {
        let navigated = loadedSelection.map { $0 != selection } ?? false
        loadedSelection = .some(selection)
        guard var checkpoint = key.checkpoint else {
            message = "No rounds yet."
            return
        }
        guard key.mode == .plan else {
            message = nil
            let raw = ShapingModel.viewerText(key.mode, checkpoint: checkpoint, tape: tape, loadFile: loadFile)
            otherText = key.mode == .diff ? PlanSection.coloredDiff(raw) : AttributedString(raw)
            if key.mode == .diff {
                let plan = ShapingModel.planText(checkpoint: checkpoint, in: tape, loadFile: loadFile) ?? ""
                diffChunks = PlanSection.diffChunks(raw, plan: plan)
                // A section the round didn't touch has no hunk; the diff then opens at its top.
                if let focus = pendingFocus {
                    diffTarget = [diffChunks.first { $0.section == focus.section }?.id ?? 0, focus.seq]
                }
                pendingFocus = nil
            }
            return
        }
        // Following the head, the plan follows the newest checkpoint WITH a plan: an encode or
        // polish checkpoint carries a change set, and resolving to it literally made the
        // editor vanish into "No plan at this checkpoint" the moment encoding began.
        if selection == nil, let head = PlanSection.planHead(tape: tape, loadFile: loadFile) { checkpoint = head }
        guard let plan = router.sent[checkpoint] ?? PlanSection.effectivePlan(checkpoint: checkpoint, tape: tape, loadFile: loadFile) else {
            message = "No plan at this checkpoint."
            return
        }
        message = nil
        if generated[checkpoint] == nil {
            generated[checkpoint] = ShapingModel.planText(checkpoint: checkpoint, in: tape, loadFile: loadFile)
        }
        let loaded = Loaded(checkpoint: checkpoint, text: plan,
                            editable: !readOnly && checkpoint == PlanSection.planHead(tape: tape, loadFile: loadFile))
        if shown == nil {
            shown = loaded
            text = plan
        } else if loaded.checkpoint == shown?.checkpoint, loaded.text == text {
            shown = loaded
            incoming = nil
        } else {
            // A new head: the editor decides whether it can take it now (`EditPolicy`) or must
            // hold it behind the banner. A round the human chose is never held — the editor
            // commits their edit to its own checkpoint and loads the choice.
            incomingIsNavigation = navigated
            incoming = loaded
        }
    }
}

/// A request to show `checkpoint`'s Diff vs Previous scrolled to `section` — sent by a heatmap
/// cell. `seq` makes a second click on the same cell a new request, so it scrolls back there.
struct PlanFocus: Equatable {
    var checkpoint: Int
    var section: String?
    var seq: Int
}

/// "Revert all 3 edits?" under the chip — Revert destructive and deliberately not the default
/// button, so Return can't throw away a plan's worth of edits; Esc cancels.
private struct RevertAllConfirmation: View {
    let prompt: String
    let onRevert: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(prompt).font(.callout.weight(.semibold))
            Text("⌘Z brings them back.").font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Revert", role: .destructive, action: onRevert)
                    .accessibilityIdentifier("plan-edit-revert-all-confirm")
            }
            .controlSize(.small)
        }
        .padding(12)
        .frame(width: 220)
    }
}
