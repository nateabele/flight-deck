import FleetKit
import SwiftUI

struct ClarificationsScreen: View {
    let intake: UUID
    let model: IntakeDetailModel
    let flightControl: FlightControlModel
    var body: some View {
        List {
            ForEach(Array((model.detail?.questions?.answered ?? []).enumerated()), id: \.offset) { round, exchange in
                Section("Round \(round + 1)") {
                    ForEach(Array(exchange.questions.enumerated()), id: \.offset) { i, q in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(q).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                            Text(exchange.answers.indices.contains(i) ? exchange.answers[i] : "").font(.subheadline)
                        }
                        .textSelection(.enabled)
                    }
                }
            }
        }
        .navigationTitle("Clarifications")
        .navigationBarTitleDisplayMode(.inline)
        .intakePresence(id: intake, model: model, flightControl: flightControl)
    }
}
