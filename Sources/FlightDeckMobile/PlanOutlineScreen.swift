import FleetKit
import SwiftUI

/// A plan's front door (spec §4.7): its sections with churn and note counts.
struct PlanOutlineScreen: View {
    let intake: UUID
    let checkpoint: Int?
    let flightControl: FlightControlModel
    @State private var plan: WireIntakePlan?
    @State private var failed = false
    @State private var query = ""

    var body: some View {
        List {
            if let plan {
                let counts = OutlineStyle.noteCounts(plan.notes, outline: plan.outline)
                ForEach(plan.outline.filter { query.isEmpty || $0.heading.localizedCaseInsensitiveContains(query) }, id: \.blockIndex) { s in
                    NavigationLink(value: IntakeRoute.reader(intake: intake, checkpoint: checkpoint, block: s.blockIndex, changes: false)) {
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(s.heading).font(.subheadline).lineLimit(1).padding(.leading, s.level > 2 ? 12 : 0)
                                if let sub = OutlineStyle.subline(s) {
                                    Text(sub).font(.caption).foregroundStyle(s.diverging ? .orange : .secondary)
                                }
                            }
                            Spacer()
                            if let n = counts[s.blockIndex] {
                                Text("\(n)").font(.caption2.weight(.bold)).padding(.horizontal, 6)
                                    // Black on solid yellow: yellow on a yellow wash vanished in light mode.
                                    .background(Capsule().fill(Color.yellow)).foregroundStyle(.black)
                                    .accessibilityLabel("\(n) note\(n == 1 ? "" : "s")")
                            }
                            churnLane(s.churn, amber: s.diverging)
                        }
                    }
                }
            } else if failed {
                Text("Couldn't load the plan.").font(.subheadline).foregroundStyle(.secondary)
            } else {
                ProgressView()
            }
        }
        .searchable(text: $query, prompt: "Find a section")
        .navigationTitle("Plan")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            if let plan {
                HStack {
                    let pending = plan.notes.filter { !$0.consumed }.count
                    Text("\(pending) note\(pending == 1 ? "" : "s") for the next round").font(.footnote)
                    Spacer()
                    NavigationLink("Whole plan", value: IntakeRoute.reader(intake: intake, checkpoint: checkpoint, block: nil, changes: false))
                        .font(.footnote)
                }
                .padding(.horizontal, 16).padding(.vertical, 10).background(.bar)
            }
        }
        .task { load() }
        .intakePresence(id: intake, model: flightControl.detailModel(for: intake), flightControl: flightControl)
    }

    private func load() {
        flightControl.plan(intake, checkpoint: checkpoint, changes: false) { result in
            switch result {
            case .success(let p): plan = p
            case .failure: failed = true
            }
        }
    }

    private func churnLane(_ churn: [Int], amber: Bool) -> some View {
        let peak = max(churn.max() ?? 1, 1)
        return HStack(alignment: .bottom, spacing: 2) {
            ForEach(Array(churn.enumerated()), id: \.offset) { _, v in
                RoundedRectangle(cornerRadius: 1).fill(amber ? Color.orange : Color.secondary)
                    .frame(width: 4, height: max(1, 14 * CGFloat(v) / CGFloat(peak)))
            }
        }
        .frame(height: 14)
        .accessibilityLabel("Lines changed per round: \(churn.map(String.init).joined(separator: ", "))")
    }
}
