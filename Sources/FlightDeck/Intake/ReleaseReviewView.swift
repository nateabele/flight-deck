import SwiftUI
import IntakeKit

/// The sheet `ProjectView` presents over an intake in `.review` (spec §8.4): every op's drift
/// against the live graph, the rating and planned delivery for each in-progress edit, and the
/// Release button that only unlocks once every drifted op is confirmed or dropped.
///
/// Loads its own `ReleaseReview` (`store.intakeService.reviewModel`) rather than being handed
/// one, and reloads it after every rating/drop/confirm action — `IntakeService` owns none of
/// this state, so the sheet is the only place that needs to know it changed.
struct ReleaseReviewView: View {
    @ObservedObject var store: SessionStore
    let intakeID: UUID
    let onClose: () -> Void

    @State private var review: ReleaseReview?
    @State private var releasing = false

    init(store: SessionStore, intakeID: UUID, onClose: @escaping () -> Void) {
        self.store = store
        self.intakeID = intakeID
        self.onClose = onClose
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Release Review").font(.headline)
                Spacer()
                Button("Close") { onClose() }
                    .keyboardShortcut(.cancelAction)
            }

            if let review {
                // Graph view: next plan (spec §8.4, phase 4).
                List {
                    sections(for: review)
                }
                .listStyle(.inset)

                Divider()

                HStack {
                    Text(footerSummary(review))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Release") { Task { await release() } }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!review.canRelease || releasing)
                        .accessibilityIdentifier("release-review-release")
                }
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(16)
        .frame(width: 620, height: 520)
        .accessibilityIdentifier("release-review")
        .task(id: intakeID) { await refresh() }
    }

    // MARK: - Sections

    @ViewBuilder
    private func sections(for review: ReleaseReview) -> some View {
        let ops = self.ops(review)
        let creates = ops.indices.filter { isCreate(ops[$0]) }
        let edges = ops.indices.filter { isEdge(ops[$0]) }
        let edits = ops.indices.filter { isEdit(ops[$0]) }
        let followUps = ops.indices.filter { isReopenOrFollowUp(ops[$0]) }

        if !creates.isEmpty {
            Section("New beads") { ForEach(creates, id: \.self) { row($0, review) } }
        }
        if !edges.isEmpty {
            Section("Edges") { ForEach(edges, id: \.self) { row($0, review) } }
        }
        if !edits.isEmpty {
            Section("Edits") { ForEach(edits, id: \.self) { row($0, review) } }
        }
        if !followUps.isEmpty {
            Section("Reopens & follow-ups") { ForEach(followUps, id: \.self) { row($0, review) } }
        }
    }

    // MARK: - Rows

    @ViewBuilder
    private func row(_ i: Int, _ review: ReleaseReview) -> some View {
        let op = ops(review)[i]
        let drift = i < review.drift.count ? review.drift[i] : .holds
        let dropped = review.intake.droppedOps.contains(i)
        let confirmed = review.intake.confirmedDrift.contains(i)

        VStack(alignment: .leading, spacing: 4) {
            detail(for: op, at: i, review: review)
                .strikethrough(dropped || isImpossible(drift))

            switch drift {
            case .impossible(let reason):
                Text(reason).font(.caption).foregroundStyle(.secondary)
            case .drifted(let reason, _):
                Text(reason).font(.caption).foregroundStyle(dropped ? Color.secondary : Color.orange)
                if dropped {
                    Text("Dropped").font(.caption2).foregroundStyle(.secondary)
                } else if confirmed {
                    Text("Confirmed").font(.caption2).foregroundStyle(.secondary)
                } else {
                    HStack {
                        Button("Confirm") { confirmDrift(i) }
                            .accessibilityIdentifier("release-review-confirm-\(i)")
                        Button("Drop", role: .destructive) { drop(i) }
                            .accessibilityIdentifier("release-review-drop-\(i)")
                    }
                }
            case .holds:
                EmptyView()
            }
        }
        .padding(.vertical, 2)
        .listRowBackground(rowBackground(drift: drift, dropped: dropped))
    }

    @ViewBuilder
    private func detail(for op: ChangeOp, at i: Int, review: ReleaseReview) -> some View {
        switch op {
        case .createBead(let bead):
            Text("\(bead.title)  (new:\(bead.tempId))")

        case .addEdge(let from, let to, _):
            HStack(spacing: 6) {
                Text("\(from.wireValue) → \(to.wireValue)")
                if isHeld(op) {
                    Text("held")
                        .font(.caption2)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        // Dashed, per spec §8.4 ("Held edges are dashed") — the graph view will
                        // draw the edge itself dashed; this list has no edge to draw, so the
                        // badge borrows the same style.
                        .overlay(Capsule().strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [3])))
                }
            }

        case .editBead(let id, let set, let pre, let delivery):
            VStack(alignment: .leading, spacing: 2) {
                Text(id).bold()
                ForEach(fieldDiff(set), id: \.self) { line in
                    Text(line).font(.caption)
                }
                if pre.status == "in_progress", let assignee = pre.assignee {
                    inProgressDetail(id: id, assignee: assignee, delivery: delivery, i: i, review: review)
                }
            }

        case .reopen(let id, let reason, _):
            Text("Reopen \(id): \(reason)")

        case .followUp(let tempId, let of, let title, _, _):
            Text("Follow-up on \(of): \(title)  (new:\(tempId))")
        }
    }

    /// The holder, an editable rating, and what release will actually do about it — mail
    /// always, plus an inject or reclaim when the holder has a live session.
    @ViewBuilder
    private func inProgressDetail(id: String, assignee: String, delivery: Delivery?, i: Int, review: ReleaseReview) -> some View {
        // Same fallback `DeliveryPlanner.plan` itself uses: a user override wins, otherwise
        // the agent's own rating from triage.
        let effective = review.intake.ratingOverrides[i] ?? delivery?.rating ?? .scopeChange
        let holderHasSession = hasSession(review, assignee)

        HStack(spacing: 6) {
            Text("Holder: \(assignee)").font(.caption)
            Picker("Rating", selection: Binding(
                get: { effective },
                set: { newValue in
                    store.intakeService.setRating(intakeID, op: i, newValue)
                    Task { await refresh() }
                }
            )) {
                ForEach(DeliveryRating.allCases, id: \.self) { rating in
                    Text(label(rating)).tag(rating)
                }
            }
            .labelsHidden()
            .frame(width: 140)
            .accessibilityIdentifier("release-review-rating-\(i)")
        }
        Text(plannedDelivery(id: id, assignee: assignee, rating: effective,
                             reason: delivery?.reason ?? "", hasSession: holderHasSession))
            .font(.caption2)
            .foregroundStyle(.secondary)
    }

    // MARK: - Footer

    private func footerSummary(_ review: ReleaseReview) -> String {
        let ops = self.ops(review)
        let held = Set(ops.indices.filter { isHeld(ops[$0]) })
        return ReleaseSummary.text(
            ops, heldOpIndices: held, drift: review.drift, dropped: review.intake.droppedOps,
            ratings: review.intake.ratingOverrides,
            hasSession: { [review] agent in hasSession(review, agent) })
    }

    /// No FD session means no way to inject or reclaim — mail is the only channel, whatever
    /// the rating. Matches `DeliveryPlanner.plan`'s own gate exactly.
    private func plannedDelivery(id: String, assignee: String, rating: DeliveryRating, reason: String, hasSession: Bool) -> String {
        guard hasSession else { return "no FD session — mail only" }
        let op = ChangeOp.editBead(id: id, set: FieldSet(),
                                   pre: Precondition(status: "in_progress", assignee: assignee),
                                   delivery: Delivery(rating: rating, reason: reason))
        let actions = DeliveryPlanner.plan(ChangeSet(graphObservedAt: .distantPast, ops: [op]),
                                           ratings: [:], hasSession: { _ in true })
        return "\(assignee): " + actions.map(\.kindName).joined(separator: " + ")
    }

    // MARK: - Actions

    private func refresh() async {
        review = await store.intakeService.reviewModel(intakeID)
    }

    private func confirmDrift(_ i: Int) {
        store.intakeService.confirmDrift(intakeID, op: i)
        Task { await refresh() }
    }

    private func drop(_ i: Int) {
        store.intakeService.drop(intakeID, op: i)
        Task { await refresh() }
    }

    private func release() async {
        releasing = true
        await store.intakeService.release(intakeID)
        releasing = false
        onClose()
    }

    // MARK: - Helpers

    private func ops(_ review: ReleaseReview) -> [ChangeOp] { review.intake.changeSet?.ops ?? [] }

    private func hasSession(_ review: ReleaseReview, _ agent: String) -> Bool {
        store.session(project: review.intake.projectPath, agentName: agent) != nil
    }

    /// The same rule `ChangeSetValidator` uses for `ValidatedChangeSet.heldOpIndices` — an
    /// `addEdge` from an existing bead to a new one blocks a live bead the moment it's
    /// written, so it waits for release. Computed directly off the op because the sheet has
    /// no live graph to hand a validator (see `ReleaseSummary`'s doc comment).
    private func isHeld(_ op: ChangeOp) -> Bool {
        if case .addEdge(let from, let to, _) = op, case .existing = from, case .new = to { return true }
        return false
    }

    private func isCreate(_ op: ChangeOp) -> Bool {
        if case .createBead = op { return true }
        return false
    }
    private func isEdge(_ op: ChangeOp) -> Bool {
        if case .addEdge = op { return true }
        return false
    }
    private func isEdit(_ op: ChangeOp) -> Bool {
        if case .editBead = op { return true }
        return false
    }
    private func isReopenOrFollowUp(_ op: ChangeOp) -> Bool {
        switch op {
        case .reopen, .followUp: true
        default: false
        }
    }
    private func isImpossible(_ drift: OpDrift) -> Bool {
        if case .impossible = drift { return true }
        return false
    }

    private func rowBackground(drift: OpDrift, dropped: Bool) -> Color {
        guard !dropped, case .drifted = drift else { return .clear }
        return Color.orange.opacity(0.12)
    }

    private func fieldDiff(_ set: FieldSet) -> [String] {
        var lines: [String] = []
        if let title = set.title { lines.append("title: \(title)") }
        if let description = set.description { lines.append("description: \(description)") }
        if let acceptance = set.acceptance { lines.append("acceptance: \(acceptance)") }
        if let priority = set.priority { lines.append("priority: \(priority)") }
        return lines
    }

    private func label(_ rating: DeliveryRating) -> String {
        switch rating {
        case .clarifying: "Clarifying"
        case .scopeChange: "Scope change"
        case .invalidating: "Invalidating"
        }
    }
}
