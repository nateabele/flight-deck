import FleetKit
import SwiftUI

/// A project's swarm on the phone: the summary (or banner), the pool meters, and Pause/Resume.
/// Launch and rule editing stay on the Mac (spec §8).
struct SwarmCard: View {
    let swarm: WireSwarm
    let inFlight: Bool
    let onPause: () -> Void
    let onResume: () -> Void
    var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(SwarmStyle.cardTitle(swarm))
                .font(.subheadline.weight(.semibold))
                .accessibilityIdentifier("swarm-card-title")
            ForEach(swarm.meters, id: \.self) { meter in
                Text(SwarmStyle.meterText(meter))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(meter.state == "overSoft" || meter.state == "overHard" ? .orange : .secondary)
                    .accessibilityIdentifier("swarm-card-meter")
            }
            if let message {
                Text(message).font(.caption).foregroundStyle(.red)
                    .accessibilityIdentifier("swarm-card-error")
            }
            HStack {
                if SwarmStyle.canPause(swarm) {
                    Button("Pause", action: onPause).accessibilityIdentifier("swarm-card-pause")
                }
                if SwarmStyle.canResume(swarm) {
                    Button("Resume", action: onResume).accessibilityIdentifier("swarm-card-resume")
                }
            }
            .buttonStyle(.bordered)
            .disabled(inFlight)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("swarm-card")
    }
}
