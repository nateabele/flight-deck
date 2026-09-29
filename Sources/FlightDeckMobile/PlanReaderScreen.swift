import FleetKit
import MarkdownUI
import SwiftUI

/// The whole plan as one scroll (spec §4.8), split with `PlanBlocks.split` — the same split the
/// Mac used to locate notes, so a note's `blockIndex` names this block. Read-only in Phase 1.
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
                    LazyVStack(alignment: .leading, spacing: 10) {
                        removed(after: nil, plan, show: showDiff)
                        ForEach(blocks, id: \.index) { block in
                            let notes = plan.notes.filter { $0.blockIndex == block.index }
                            Markdown(block.text)
                                .markdownTheme(TimelineMarkdown.theme)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(RoundedRectangle(cornerRadius: 4).fill(
                                    added.contains(block.index) ? Color.green.opacity(0.12)
                                    : notes.contains { !$0.consumed } ? Color.yellow.opacity(0.14)
                                    : notes.isEmpty ? Color.clear : Color.yellow.opacity(0.06)))
                                .modifier(NoteTap(count: notes.count) { openBlock = BlockNotes(id: block.index) })
                                .id(block.index)
                            removed(after: block.index, plan, show: showDiff)
                        }
                        let detached = plan.notes.filter { $0.blockIndex == nil && !$0.consumed }
                        if !detached.isEmpty {
                            Divider()
                            Text("Notes not pinned to a passage").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                            ForEach(detached, id: \.id) { n in noteCard(n) }
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
        .sheet(item: $openBlock) { item in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(plan?.notes.filter { $0.blockIndex == item.id } ?? [], id: \.id) { n in noteCard(n) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
            .presentationDetents([.medium])
        }
        .task(id: changes) { load() }
        .intakePresence(id: intake, model: flightControl.detailModel(for: intake), flightControl: flightControl)
    }

    /// Tap, button trait and "N notes" label only on a block that has notes; a block without
    /// any is plain content and takes no gesture.
    private struct NoteTap: ViewModifier {
        let count: Int
        let open: () -> Void
        func body(content: Content) -> some View {
            if count > 0 {
                content.onTapGesture(perform: open)
                    .accessibilityAddTraits(.isButton)
                    .accessibilityHint("\(count) note\(count == 1 ? "" : "s")")
            } else {
                content
            }
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
        }
        .opacity(n.consumed ? 0.7 : 1)
    }

    private func load() {
        let token = requests.begin()
        let asked = changes
        failed = false
        flightControl.plan(intake, checkpoint: checkpoint, changes: asked) { result in
            guard requests.accepts(token) else { return }
            switch result {
            case .success(let p): plan = p; loadedChanges = asked
            case .failure: failed = true
            }
        }
    }
}
