import IntakeKit
import SwiftUI

/// The `.shaping` body of an intake (spec §8.3): the tape, the transport bar, what each
/// button would run, why the runner stopped, one card per round, and the plan at any
/// checkpoint. Every decision lives in `ShapingModel`; this view only lays it out.
///
/// Inputs are injected rather than read off `IntakeService` — `loadFile(checkpointID,
/// relativePath)` reads a file out of `checkpoints/<id>/`, and `onSend` queues a
/// `TapeCommand` for the runner — so Task 11 can wire it to the service without this view
/// knowing where tapes live, and so it can be rendered in isolation.
struct ShapingView: View {
    let intake: Intake
    let tape: Tape
    let loadFile: (Int, String) -> Data?
    let onSend: (TapeCommand) -> Void

    /// nil means "follow the head", so a new checkpoint landing moves the viewer with it
    /// unless the human has deliberately picked an older round.
    @State private var selectedCheckpoint: Int?
    @State private var viewerMode: ShapingModel.ViewerMode = .plan
    @State private var annotating = false
    @State private var extending = false
    /// The rendered viewer text, recomputed only when `ShapingModel.ViewerKey` changes.
    @State private var viewerText = AttributedString()

    init(intake: Intake, tape: Tape, loadFile: @escaping (Int, String) -> Data?,
         onSend: @escaping (TapeCommand) -> Void, viewerMode: ShapingModel.ViewerMode = .plan) {
        self.intake = intake
        self.tape = tape
        self.loadFile = loadFile
        self.onSend = onSend
        _viewerMode = State(initialValue: viewerMode)
    }

    var body: some View {
        let model = ShapingModel(intake: intake, tape: tape)
        VStack(alignment: .leading, spacing: 12) {
            TapeStrip(model: model)
            transportBar(model)
            Text(Self.textPresentation(model.statusLine))
                .font(.callout)
                .foregroundStyle(tape.status == .failed ? Color.orange : Color.secondary)
                .textSelection(.enabled)
                .accessibilityIdentifier("shaping-status")
            if let banner = model.pauseBanner {
                pauseBanner(banner)
            }
            if !tape.pendingNotes.isEmpty {
                let n = tape.pendingNotes.count
                Text("✎ \(n) note\(n == 1 ? "" : "s") queued for the next round")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !model.roundCards.isEmpty {
                roundCards(model)
            }
            planViewer
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("shaping-view")
        .sheet(isPresented: $annotating) {
            AnnotateSheet(onSend: { onSend(.annotate($0)) }, onClose: { annotating = false })
        }
    }

    // MARK: - Transport

    private func transportBar(_ model: ShapingModel) -> some View {
        let on = model.enabled
        return HStack(spacing: 6) {
            transportButton("⏯", "step", "transport-step", enabled: on.contains(.step)) { onSend(.step) }
            transportButton("⏭", "next major", "transport-next-major", enabled: on.contains(.nextMajor)) { onSend(.nextMajor) }
            transportButton("⏩", "to review", "transport-to-review", enabled: on.contains(.toReview)) { onSend(.toReview) }
            transportButton("⏸", "pause", "transport-pause", enabled: on.contains(.pause)) { onSend(.pause) }
            transportButton("⏹", "stop", "transport-stop", enabled: on.contains(.stop)) { onSend(.stop) }
            Divider().frame(height: 30)
            // A popover rather than a `Menu`: a bordered `Menu` flattens its label to one line,
            // which dropped the "extend" caption every other transport button carries.
            transportButton("＋", "extend", "transport-extend",
                            enabled: on.contains(.extend) && !model.extendStages.isEmpty) { extending = true }
                .popover(isPresented: $extending, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(model.extendStages, id: \.self) { stage in
                            Button(stage == .refine ? "+1 refine round" : "+1 polish round") {
                                extending = false
                                onSend(.extend(stage, by: 1))
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                    .padding(10)
                }
            transportButton("✎", "annotate", "transport-annotate", enabled: on.contains(.annotate)) { annotating = true }
        }
    }

    private func transportButton(_ symbol: String, _ caption: String, _ identifier: String,
                                 enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { transportLabel(symbol, caption) }
            .buttonStyle(.bordered)
            .disabled(!enabled)
            .help(caption.prefix(1).uppercased() + caption.dropFirst())
            .accessibilityIdentifier(identifier)
    }

    private func transportLabel(_ symbol: String, _ caption: String) -> some View {
        VStack(spacing: 1) {
            Text(Self.textPresentation(symbol)).font(.system(size: 14))
            Text(caption).font(.system(size: 9)).foregroundStyle(.secondary)
        }
        .frame(minWidth: 44)
    }

    /// ⏩ defaults to emoji presentation and renders as a blue tile beside its monochrome
    /// neighbours; U+FE0E asks for the text glyph. Applied at display time so the model's
    /// strings (and their tests) stay plain.
    static func textPresentation(_ s: String) -> String {
        s.replacingOccurrences(of: "⏩", with: "⏩\u{FE0E}")
    }

    // MARK: - Banner

    private func pauseBanner(_ banner: (title: String, action: String)) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(banner.title).font(.callout.weight(.semibold))
                Text(Self.textPresentation(banner.action)).font(.callout).foregroundStyle(.secondary)
            }
            .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
        .accessibilityIdentifier("shaping-pause-banner")
    }

    // MARK: - Round cards

    private func roundCards(_ model: ShapingModel) -> some View {
        let selected = selectedCheckpoint ?? tape.head?.id
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 6) {
                ForEach(model.roundCards) { card in
                    roundCard(card, selected: card.checkpointID == selected)
                        .onTapGesture {
                            // Clicking the head again returns to following it.
                            selectedCheckpoint = card.checkpointID == tape.head?.id ? nil : card.checkpointID
                        }
                }
            }
        }
    }

    private func roundCard(_ card: RoundCard, selected: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(card.title).font(.caption.weight(.semibold))
            Text([card.changes, card.lines].compactMap { $0 }.joined(separator: " · "))
                .font(.caption2)
                .foregroundStyle(.secondary)
            if let tally = card.tally {
                Text(tally).font(.caption2).foregroundStyle(.secondary)
            }
            if let sections = card.sections {
                Text(sections).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            // Expanded only on the selected card: a row of cards each carrying a paragraph
            // would push the viewer off screen. Every card keeps it as hover text.
            if selected, let note = card.note {
                // A horizontal scroll view proposes unlimited width, so without a cap the
                // note would lay out as one long line instead of wrapping.
                Text(note).font(.caption2).foregroundStyle(.secondary).lineLimit(6)
                    .frame(maxWidth: 220, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !card.slots.isEmpty {
                HStack(spacing: 3) {
                    ForEach(card.slots.indices, id: \.self) { i in slotBadge(card.slots[i]) }
                }
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(selected ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5)
            .strokeBorder(selected ? Color.accentColor : Color.secondary.opacity(0.2), lineWidth: 1))
        .contentShape(Rectangle())
        .help(card.note ?? "")
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("round-card-\(card.checkpointID)")
    }

    private func slotBadge(_ slot: SlotBadge) -> some View {
        let (glyph, color): (String, Color) = switch slot.status {
        case .ok: ("✓", .secondary)
        case .substituted: ("⇄", .orange)
        case .failed: ("✕", .red)
        }
        return Text(glyph)
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(color)
            .frame(width: 14, height: 14)
            .background(color.opacity(0.15), in: Circle())
            .help(slot.diagnosis.map { "\(slot.label): \($0)" } ?? slot.label)
    }

    // MARK: - Plan viewer

    private var planViewer: some View {
        let key = ShapingModel.viewerKey(selected: selectedCheckpoint, mode: viewerMode, tape: tape)
        return VStack(alignment: .leading, spacing: 6) {
            Picker("View", selection: $viewerMode) {
                Text("Plan").tag(ShapingModel.ViewerMode.plan)
                Text("Diff vs previous").tag(ShapingModel.ViewerMode.diff)
                Text("Change set").tag(ShapingModel.ViewerMode.changeSet)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            // Vertical only: a horizontal axis gives the text infinite width, which centred it.
            ScrollView(.vertical) {
                Text(viewerText)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(key.checkpoint == nil ? .secondary : .primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(8)
            }
            .frame(minHeight: 240, maxHeight: .infinity)
            .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
        }
        .accessibilityIdentifier("plan-viewer")
        // `initial: true` is the `.onAppear` half: it computes the text once on first render,
        // then again only when the key changes.
        .onChange(of: key, initial: true) { _, key in
            let text = ShapingModel.viewerContent(key, tape: tape, loadFile: loadFile)
            viewerText = key.mode == .diff ? Self.coloredDiff(text) : AttributedString(text)
        }
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
}

// MARK: - Annotate

/// Its own view so the draft lives in its own `@State`: held on `ShapingView`, every keystroke
/// re-evaluated the whole shaping body — model, strip, cards and all.
private struct AnnotateSheet: View {
    let onSend: (String) -> Void
    let onClose: () -> Void
    @State private var annotation = ""

    var body: some View {
        let trimmed = annotation.trimmingCharacters(in: .whitespacesAndNewlines)
        VStack(alignment: .leading, spacing: 12) {
            Text("Annotate the next round").font(.headline)
            Text("The runner hands this note to the next round's agents.")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextEditor(text: $annotation)
                .font(.body)
                .frame(minHeight: 120)
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.secondary.opacity(0.3)))
                .accessibilityIdentifier("annotate-text")
            HStack {
                Spacer()
                Button("Cancel", action: onClose)
                    .keyboardShortcut(.cancelAction)
                Button("Send") {
                    onSend(trimmed)
                    onClose()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(trimmed.isEmpty)
                .accessibilityIdentifier("annotate-send")
            }
        }
        .padding(16)
        .frame(width: 420)
    }
}
