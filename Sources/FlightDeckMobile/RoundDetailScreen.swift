import FleetKit
import SwiftUI

/// A landed round (spec §4.6), from a board dot or a Rounds row; ‹ › step to its neighbours.
struct RoundDetailScreen: View {
    let intake: UUID
    @State var checkpoint: Int
    let model: IntakeDetailModel
    let flightControl: FlightControlModel

    init(intake: UUID, checkpoint: Int, model: IntakeDetailModel, flightControl: FlightControlModel) {
        self.flightControl = flightControl
        self.intake = intake; self._checkpoint = State(initialValue: checkpoint); self.model = model
    }

    private var rounds: [WireRound] { (model.detail?.rounds ?? []).sorted { $0.checkpoint < $1.checkpoint } }
    private var round: WireRound? { rounds.first { $0.checkpoint == checkpoint } }

    var body: some View {
        List {
            if let r = round {
                let facts = RoundFacts(r)
                Section {
                    HStack(spacing: 0) {
                        fact("Time", facts.time); Divider(); fact("Changes", facts.changes)
                        Divider(); fact("Lines", facts.lines); Divider(); fact("Verdicts", facts.verdicts)
                    }
                    .accessibilityElement(children: .ignore).accessibilityLabel(facts.spoken)
                }
                if let note = r.note { Section("Note") { Text(note).font(.subheadline).textSelection(.enabled) } }
                if !r.agents.isEmpty {
                    Section("Agents") {
                        ForEach(Array(r.agents.enumerated()), id: \.offset) { _, a in
                            VStack(alignment: .leading, spacing: 1) {
                                Text(a.role.capitalized).font(.subheadline)
                                Text(a.ran).font(.caption).foregroundStyle(.secondary)
                                if let detail = a.detail {
                                    Text(detail).font(.caption).foregroundStyle(a.status == "failed" ? .red : .orange)
                                }
                            }
                        }
                    }
                }
                if !r.sectionsChanged.isEmpty {
                    Section("Sections changed · \(r.sectionsChanged.count)") {
                        ForEach(r.sectionsChanged, id: \.self) { s in
                            NavigationLink(value: IntakeRoute.reader(intake: intake, checkpoint: r.checkpoint == model.detail?.headCheckpoint ? nil : r.checkpoint, block: nil, changes: true)) {
                                Text(s).font(.subheadline).lineLimit(1)
                            }
                        }
                    }
                }
                if !r.notesConsumed.isEmpty {
                    Section("Notes consumed · \(r.notesConsumed.count)") {
                        ForEach(r.notesConsumed, id: \.id) { n in
                            VStack(alignment: .leading, spacing: 2) {
                                if let q = n.quote { Text("“\(q)”").font(.caption).italic().foregroundStyle(.secondary) }
                                Text(n.text.isEmpty ? "Highlight" : n.text).font(.subheadline)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(round?.name ?? "Round")
        .navigationBarTitleDisplayMode(.inline)
        .intakePresence(id: intake, model: model, flightControl: flightControl)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { step(-1) } label: { Image(systemName: "chevron.left") }
                    .disabled(rounds.first?.checkpoint == checkpoint).accessibilityLabel("Previous round")
                Button { step(1) } label: { Image(systemName: "chevron.right") }
                    .disabled(rounds.last?.checkpoint == checkpoint).accessibilityLabel("Next round")
            }
        }
    }

    private func step(_ delta: Int) {
        guard let i = rounds.firstIndex(where: { $0.checkpoint == checkpoint }), rounds.indices.contains(i + delta) else { return }
        checkpoint = rounds[i + delta].checkpoint
    }

    private func fact(_ label: String, _ value: String) -> some View {
        VStack(spacing: 1) {
            Text(label.uppercased()).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.subheadline.weight(.semibold).monospacedDigit()).lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
    }
}
