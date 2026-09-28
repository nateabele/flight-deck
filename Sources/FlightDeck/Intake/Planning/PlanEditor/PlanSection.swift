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

    init(intakeID: UUID, tape: Tape, loadFile: @escaping (Int, String) -> Data?, onSend: @escaping (TapeCommand) -> Void,
         selection: Binding<Int?> = .constant(nil), mode: ShapingModel.ViewerMode = .plan) {
        self.intakeID = intakeID
        self.tape = tape
        self.loadFile = loadFile
        self.onSend = onSend
        _selection = selection
        initialMode = mode
    }

    var body: some View {
        // Keyed on the intake so switching intakes starts a fresh editor, instead of offering
        // the other intake's plan as "a new round landed".
        PlanSectionBody(tape: tape, loadFile: loadFile, onSend: onSend, selection: $selection, mode: initialMode,
                        hooks: editHooks)
            .id(intakeID)
    }

    /// Where the edit layer reports to the intake (`PlanEditHooks`).
    func editHooks(_ hooks: PlanEditHooks) -> PlanSection {
        var copy = self
        copy.editHooks = hooks
        return copy
    }

    /// What the plan tab shows for a checkpoint: the effective plan (`plan.user.md` if the
    /// human edited it, else what the round generated) — the same layer the next round reads.
    /// `PlanLayers.effectivePlan` takes a directory; this is its rule over `loadFile`.
    static func effectivePlan(checkpoint: Int, tape: Tape, loadFile: (Int, String) -> Data?) -> String? {
        if let edited = loadFile(checkpoint, PlanLayers.userName) { return String(decoding: edited, as: UTF8.self) }
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

private struct PlanSectionBody: View {
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
    /// Edits sent but maybe not yet applied by the runner: reloading the checkpoint from disk
    /// before then would offer the pre-edit plan back as if it were news.
    @State private var sent: [Int: String] = [:]
    @State private var otherText = AttributedString()
    @State private var message: String?
    let hooks: PlanEditHooks
    /// Each checkpoint's generated plan — the edit layer's base. Written once per checkpoint
    /// and never modified, so it is read once.
    @State private var generated: [Int: String] = [:]
    /// "Your edits are kept…", up in this section since it first showed (`PlanEditHooks`).
    @State private var showKeptNote = false
    /// Checkpoints whose edit could not be carried onto a newer head: later commits of the
    /// same edit stay with it, rather than merging a remainder onto the head without the part
    /// that conflicted.
    @State private var stuck: Set<Int> = []
    /// The last stale-edit merge, so the next waits for it: each merges onto the head as the
    /// one before it left it.
    @State private var retargeting: Task<Void, Never>?

    struct Loaded: Equatable {
        var checkpoint: Int
        var text: String
        var editable: Bool
    }

    init(tape: Tape, loadFile: @escaping (Int, String) -> Data?, onSend: @escaping (TapeCommand) -> Void,
         selection: Binding<Int?>, mode: ShapingModel.ViewerMode, hooks: PlanEditHooks) {
        self.tape = tape
        self.loadFile = loadFile
        self.onSend = onSend
        _selection = selection
        _mode = State(initialValue: mode)
        self.hooks = hooks
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

            if mode == .plan, let shown, !shown.editable {
                pastBar(shown.checkpoint)
            }
            content
                .frame(minHeight: 240, maxHeight: .infinity)
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
                Button("Revert all", action: revertAll)
                    .buttonStyle(.plain)
                    .fontWeight(.semibold)
                    .accessibilityIdentifier("plan-edit-revert-all")
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

    /// Every hunk back to the agents' text: the runner stores a plan identical to the
    /// generated one as "no edits" (`TapeStore.writeUserEdits`).
    private func revertAll() {
        guard let shown, shown.editable, let base = generated[shown.checkpoint] else { return }
        commitEdit(base, to: shown)
        text = base
    }

    /// Sends an edit for the checkpoint it was typed on — unless a newer head has landed since
    /// (Task 10's open end). Then the edit, kept there, would feed no round, so it is merged
    /// onto the head by the runner's own rule (`EditLayer.retarget`) and sent for the head; a
    /// conflict keeps it where it was typed and raises the banner.
    private func commitEdit(_ markdown: String, to loaded: Loaded) {
        let checkpoint = loaded.checkpoint
        let head = PlanSection.planHead(tape: tape, loadFile: loadFile)
        guard let head, head != checkpoint, loaded.editable, !stuck.contains(checkpoint) else {
            sent[checkpoint] = markdown
            return onSend(.editPlan(checkpoint: checkpoint, markdown: markdown))
        }
        // The runner already failed to carry this checkpoint's edits into the head; merging
        // more of them onto it would land the rest without the part that conflicted.
        if tape.checkpoints.first(where: { $0.id == head })?.record.editConflict == checkpoint {
            stuck.insert(checkpoint)
            sent[checkpoint] = markdown
            return onSend(.editPlan(checkpoint: checkpoint, markdown: markdown))
        }
        // What the edit was typed on: the checkpoint's text before the head moved. Commits since
        // then went to the head, so this is still the last one sent for it (or the load).
        let base = sent[checkpoint] ?? loaded.text
        let previous = retargeting
        retargeting = Task { @MainActor in
            await previous?.value
            guard let ours = sent[head] ?? PlanSection.effectivePlan(checkpoint: head, tape: tape, loadFile: loadFile) else { return }
            let outcome = await EditLayer.retarget(markdown: markdown, typedOn: checkpoint, base: base, head: head,
                                                   headPlan: ours, runner: hooks.runner)
            guard case .editPlan(let target, let plan) = outcome.command else { return }
            sent[target] = plan
            onSend(outcome.command)
            if let conflict = outcome.conflict {
                stuck.insert(checkpoint)
                return hooks.onConflict(conflict)
            }
            // The head's text on screen or waiting behind the banner predates the merge.
            if shown?.checkpoint == head, text == ours {
                shown?.text = plan
                text = plan
            } else if incoming?.checkpoint == head {
                incoming?.text = plan
            }
        }
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
        } else {
            // Vertical only: a horizontal axis gives the text infinite width, which centred it.
            ScrollView(.vertical) {
                Text(otherText)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(8)
            }
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
            return
        }
        // Following the head, the plan follows the newest checkpoint WITH a plan: an encode or
        // polish checkpoint carries a change set, and resolving to it literally made the
        // editor vanish into "No plan at this checkpoint" the moment encoding began.
        if selection == nil, let head = PlanSection.planHead(tape: tape, loadFile: loadFile) { checkpoint = head }
        guard let plan = sent[checkpoint] ?? PlanSection.effectivePlan(checkpoint: checkpoint, tape: tape, loadFile: loadFile) else {
            message = "No plan at this checkpoint."
            return
        }
        message = nil
        if generated[checkpoint] == nil {
            generated[checkpoint] = ShapingModel.planText(checkpoint: checkpoint, in: tape, loadFile: loadFile)
        }
        let loaded = Loaded(checkpoint: checkpoint, text: plan,
                            editable: checkpoint == PlanSection.planHead(tape: tape, loadFile: loadFile))
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
