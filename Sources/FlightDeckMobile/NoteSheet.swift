import SwiftUI

/// The half sheet a plan note is written in (spec §4.8): what it is about, the kind, the words.
///
/// The sheet owns only its draft; sending is the reader's, which knows the intake and the
/// command model. **Highlight sends at once** with no text — it is a mark on the selection, as
/// the Mac's toolbar makes it — so there is nothing left to write and no Add to press.
///
/// Keyboard: this relies on SwiftUI's own sheet keyboard avoidance rather than
/// `KeyboardOverlapReader`. That reader exists for the timeline's composer, which follows an
/// interactive dismissal frame by frame with avoidance turned off; a sheet has no interactive
/// dismissal to follow, and at `.medium` the system lifts it above the keyboard. Whether the
/// field stays visible at `.medium` on a device is MOBILE.md's to confirm.
struct NoteSheet: View {
    @State private var draft: NoteDraft
    let onAdd: (NoteDraft) -> Void
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool

    init(draft: NoteDraft, onAdd: @escaping (NoteDraft) -> Void) {
        self._draft = State(initialValue: draft)
        self.onAdd = onAdd
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    subject
                    kinds
                    TextField("What should the next round know?", text: $draft.text, axis: .vertical)
                        .font(.body)
                        .lineLimit(3...10)
                        .focused($focused)
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color(.secondarySystemBackground)))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Note for next round")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Text("Cancel").font(.body) }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button { onAdd(draft) } label: { Text("Add").font(.body.weight(.semibold)) }
                        .disabled(!NoteComposer.canAdd(kind: draft.kind, text: draft.text))
                }
            }
        }
        .presentationDetents([.medium, .large])
        .onAppear { focused = true }
    }

    /// The quote, with the accent bar Mail and Messages use for a quotation; or, with no phrase,
    /// words for what the note is about, so the sheet never opens on nothing.
    @ViewBuilder private var subject: some View {
        if let quote = draft.target.quote {
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5).fill(Color.accentColor).frame(width: 3)
                Text(quote).font(.subheadline).italic().foregroundStyle(.secondary).lineLimit(6)
            }
            .fixedSize(horizontal: false, vertical: true)
        } else {
            Text(draft.target.block == nil ? "About the whole plan" : "About this passage")
                .font(.subheadline).foregroundStyle(.secondary)
        }
    }

    private var kinds: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(NoteComposer.kinds(for: draft.target), id: \.id) { kind in
                    let selected = draft.kind == kind.id
                    Button {
                        if NoteComposer.wire(kind: kind.id).sendsImmediately {
                            var mark = draft
                            mark.kind = kind.id
                            mark.text = ""
                            onAdd(mark)
                        } else {
                            draft.kind = kind.id
                        }
                    } label: {
                        Text(kind.title)
                            .font(.subheadline.weight(selected ? .semibold : .regular))
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(Capsule().fill(selected ? Color.accentColor.opacity(0.2) : Color(.secondarySystemFill)))
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
        }
    }
}
