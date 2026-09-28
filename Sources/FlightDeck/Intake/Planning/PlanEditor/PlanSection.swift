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
        PlanSectionBody(tape: tape, loadFile: loadFile, onSend: onSend, selection: $selection, mode: initialMode)
            .id(intakeID)
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

    /// Green/red per line, as in the mockup's hunk pane. A single `AttributedString` rather
    /// than one `Text` per line so a long diff stays one text view (and one selection).
    static func coloredDiff(_ diff: String) -> AttributedString {
        var out = AttributedString()
        for (i, line) in diff.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            var piece = AttributedString((i == 0 ? "" : "\n") + line)
            if line.hasPrefix("+") { piece.foregroundColor = .green }
            else if line.hasPrefix("-") { piece.foregroundColor = .red }
            else if line.hasPrefix("@@") { piece.foregroundColor = .secondary }
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

    struct Loaded: Equatable {
        var checkpoint: Int
        var text: String
        var editable: Bool
    }

    init(tape: Tape, loadFile: @escaping (Int, String) -> Data?, onSend: @escaping (TapeCommand) -> Void,
         selection: Binding<Int?>, mode: ShapingModel.ViewerMode) {
        self.tape = tape
        self.loadFile = loadFile
        self.onSend = onSend
        _selection = selection
        _mode = State(initialValue: mode)
    }

    var body: some View {
        let key = ShapingModel.viewerKey(selected: selection, mode: mode, tape: tape)
        VStack(alignment: .leading, spacing: 6) {
            Picker("View", selection: $mode) {
                Text("Plan").tag(ShapingModel.ViewerMode.plan)
                Text("Diff vs Previous").tag(ShapingModel.ViewerMode.diff)
                Text("Change set").tag(ShapingModel.ViewerMode.changeSet)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            if mode == .plan, let shown, !shown.editable {
                pastBar(shown.checkpoint)
            }
            content
                .frame(minHeight: 240, maxHeight: .infinity)
                .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
        }
        .accessibilityIdentifier("plan-viewer")
        .onChange(of: key, initial: true) { _, key in reload(key) }
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
                         onCommit: { markdown in
                             sent[shown.checkpoint] = markdown
                             onSend(.editPlan(checkpoint: shown.checkpoint, markdown: markdown))
                         },
                         incoming: incoming?.text,
                         onShowIncoming: {
                             guard let incoming else { return }
                             self.shown = incoming
                             text = incoming.text
                             self.incoming = nil
                             incomingIsNavigation = false
                         },
                         incomingIsNavigation: incomingIsNavigation)
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
