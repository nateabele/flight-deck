import FleetKit
import SwiftUI

/// One agent in the round in flight (spec §4.4).
struct AgentRow: View {
    let agent: WireAgent
    let now: Date   // skew-corrected

    var body: some View {
        let exception = AgentRowStyle.exception(agent, now: now)
        HStack(alignment: .top, spacing: 10) {
            glyph.padding(.top, 3)
            VStack(alignment: .leading, spacing: 2) {
                Text(agent.result ?? agent.headline ?? agent.action ?? "Queued").font(.subheadline).lineLimit(2)
                if !AgentRowStyle.finished(agent), let action = agent.action, action != agent.headline {
                    Text(action).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Text("\(agent.role.capitalized) · \(agent.identity)").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                if let steps = agent.steps { Text(steps).font(.caption2).foregroundStyle(.secondary) }
                if let e = exception {
                    Text(AgentRowStyle.exceptionText(e)).font(.caption).foregroundStyle(Self.color(e))
                }
                if let fraction = agent.contextFraction, !AgentRowStyle.finished(agent) {
                    ProgressView(value: min(max(fraction, 0), 1)).tint(.secondary).scaleEffect(y: 0.6)
                        .accessibilityLabel("Context used").accessibilityValue("\(Int(fraction * 100)) percent")
                }
            }
            Spacer(minLength: 0)
            if let elapsed = AgentRowStyle.elapsed(agent, now: now) {
                Text(ClockPolicy.text(elapsed)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(AgentRowStyle.accessibilityLabel(agent, now: now))
    }

    static func color(_ e: AgentException) -> Color {
        if case .failed = e { return .red }
        return AgentRowStyle.isAmber(e) ? .orange : .secondary
    }

    @ViewBuilder private var glyph: some View {
        switch agent.glyph {
        case "running": Circle().fill(Color.accentColor).frame(width: 9, height: 9)
        case "fallback": Image(systemName: "arrow.left.arrow.right").font(.caption2).foregroundStyle(.orange)
        case "failed": Image(systemName: "xmark").font(.caption2.weight(.bold)).foregroundStyle(.red)
        case "done": Circle().fill(Color.secondary).frame(width: 9, height: 9)
        default: Circle().stroke(Color.secondary).frame(width: 9, height: 9)
        }
    }
}
