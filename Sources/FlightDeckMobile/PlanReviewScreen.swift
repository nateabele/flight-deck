import FleetKit
import MarkdownUI
import SwiftUI

/// The plan itself: one block per row, a target block opening a comment sheet, and a footer
/// that carries whatever was typed into whichever verdict is pressed.
///
/// **Drawn with `TimelineMarkdown.theme`** — the same theme the conversation itself uses, so a
/// plan two taps from the timeline does not read as a second app. And **split with
/// `PlanBlocks.split(_:)`**, never a rule of this screen's own: `PlanReviewModel` already did
/// that, for the reason `PlanBlocks` gives — the Mac resolves a comment's block index against
/// its own split of the same text, and a disagreement here is a comment pinned to the wrong
/// phrase there.
struct PlanReviewScreen: View {
    @Bindable var model: PlanReviewModel

    /// The block a tap opened a sheet for. Wrapped rather than presenting `PlanBlocks.Block`
    /// itself: that type is shared with the Mac in `FleetKit` and deliberately only
    /// `Equatable`, and `sheet(item:)` needs `Identifiable` — conforming it retroactively from
    /// here would reach into a cross-platform type for one screen's presentation plumbing.
    private struct CommentTarget: Identifiable {
        let block: PlanBlocks.Block
        var id: Int { block.index }
    }
    @State private var commentTarget: CommentTarget?
    /// Which row is under a finger right now, so its container can highlight — set and cleared
    /// by the drag-recognising half of `tapTarget(_:)`, never by the tap itself, which only
    /// fires on release.
    @State private var pressedBlock: Int?
    /// The verdict this screen itself sent, captured in the button action at the moment it is
    /// pressed — before `model.resolve` runs — so the read-only footer can say which one it
    /// was. `PlanReviewModel.resolved` is deliberately just a latch (see its own comment); it
    /// is this screen, not the model, that needs to remember which button that latch belongs to.
    @State private var chosenApprove: Bool?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                // Once, above every block, never per block — see Self.limitedNotice.
                if let notice = Self.limitedNotice(tier: model.gate.tier) {
                    Text(notice)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(model.blocks, id: \.index) { block in
                    blockRow(block)
                }
            }
            .padding(16)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Review the plan")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $commentTarget) { target in
            CommentSheet(blockIndex: target.block.index) { text in
                model.comment(on: target.block.index, text: text)
            }
        }
        .safeAreaInset(edge: .bottom) {
            if model.resolved {
                resolvedFooter
            } else {
                verdictFooter
            }
        }
    }

    /// The `verdict`-tier notice, said exactly once above the plan — never per block, because a
    /// reader who cannot pin a comment on ANY block does not need to be told that thirty times.
    /// `nil` in the `annotate` tier, where pinning works and there is nothing to explain.
    static func limitedNotice(tier: String) -> String? {
        guard tier != "annotate" else { return nil }
        return "Inline comments need Plannotator running on your Mac. "
            + "You can still read the plan and send a verdict."
    }

    // MARK: Blocks

    private func blockRow(_ block: PlanBlocks.Block) -> some View {
        let count = model.sent[block.index]?.count ?? 0
        return Markdown(block.text)
            .markdownTheme(TimelineMarkdown.theme)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(
                        pressedBlock == block.index
                            ? Color(.tertiarySystemBackground)
                            : Color(.secondarySystemBackground)
                    )
            )
            .overlay(alignment: .topTrailing) {
                if count > 0 {
                    Text("💬 \(count)")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color(.tertiarySystemBackground)))
                        .padding(6)
                }
            }
            .modifier(TapTarget(
                isTarget: model.canComment(on: block.index),
                index: block.index,
                pressed: $pressedBlock
            ) {
                commentTarget = CommentTarget(block: block)
            })
    }

    // MARK: Footer

    private var verdictFooter: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            TextField("Add a note (optional)", text: $model.feedback, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.body)
                .lineLimit(1...4)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color(.secondarySystemBackground))
                )
            // Both carry `model.feedback` — approving with notes is one action, not "send
            // notes, then approve" (see `PlanReviewModel.resolve`'s own comment).
            HStack(spacing: 8) {
                Button(role: .destructive) {
                    chosenApprove = false
                    model.resolve(approve: false)
                } label: {
                    Text("Request changes").frame(maxWidth: .infinity)
                }
                Button {
                    chosenApprove = true
                    model.resolve(approve: true)
                } label: {
                    Text("Approve").frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            // Belt and braces alongside `PlanReviewModel.resolve`'s own `!resolved` guard: that
            // guard is what actually keeps a double tap off the socket, since the two taps of a
            // fast double-tap can both land before this view re-renders into `resolvedFooter`.
            // Disabling here just keeps the buttons from looking tappable a frame longer than
            // they are.
            .disabled(model.resolved)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(.systemBackground))
    }

    private var resolvedFooter: some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider()
            Label(
                Self.resolvedTitle(approved: chosenApprove),
                systemImage: chosenApprove == false
                    ? "arrow.uturn.left.circle.fill" : "checkmark.circle.fill"
            )
            .font(.callout.weight(.medium))
            .foregroundStyle(chosenApprove == false ? .orange : .green)
            if !model.feedback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(model.feedback)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(.systemBackground))
    }

    /// `chosenApprove` is `nil` only when this screen's own buttons never ran — a gate already
    /// resolved before this instance existed. That should not happen given how the banner
    /// reaches this screen, but a fallback sentence beats a blank footer if it ever does.
    static func resolvedTitle(approved: Bool?) -> String {
        switch approved {
        case true: return "You approved this plan."
        case false: return "You asked for changes."
        case nil: return "This plan has been resolved."
        }
    }
}

/// A target block gets a tap; a non-target draws identically and takes none — never hidden,
/// never given a gesture that goes nowhere. The press-highlight is a `DragGesture` with no
/// minimum distance rather than the tap itself, because a plain `onTapGesture` reports only
/// the release: without a separate touch-down signal there is nothing to highlight while a
/// finger is still down.
private struct TapTarget: ViewModifier {
    let isTarget: Bool
    let index: Int
    @Binding var pressed: Int?
    let action: () -> Void

    func body(content: Content) -> some View {
        if isTarget {
            content
                .contentShape(Rectangle())
                .onTapGesture(perform: action)
                .simultaneousGesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { _ in pressed = index }
                        .onEnded { _ in if pressed == index { pressed = nil } }
                )
        } else {
            content
        }
    }
}

/// One comment, on one block. Presented modally rather than inline, so typing it does not
/// scroll the plan out from under the row it is about.
private struct CommentSheet: View {
    let blockIndex: Int
    let onSend: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @FocusState private var isFocused: Bool

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                TextField("Comment", text: $text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.body)
                    .lineLimit(4...10)
                    .focused($isFocused)
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color(.secondarySystemBackground))
                    )
                Spacer()
            }
            .padding(16)
            .navigationTitle("Comment")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") {
                        onSend(text)
                        dismiss()
                    }
                    .disabled(!canSend)
                }
            }
        }
        .presentationDetents([.medium])
        .onAppear { isFocused = true }
    }
}
