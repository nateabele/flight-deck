import FleetKit
import SwiftUI

/// The pinned phosphor strip (spec §4.3). Phase 1 has no transport row.
struct BoardStrip: View {
    let model: BoardStripModel
    let offset: TimeInterval
    let frozenAt: Date?
    let onDot: (Int) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var phosphor: Color {
        switch model.tone {
        case .live: Color(red: 0.49, green: 0.88, blue: 1)
        case .attention: .orange
        case .failure: .red
        case .quiet: Color(white: 0.8)
        }
    }

    var body: some View {
        TimelineView(ClockSchedule(since: model.clockSince, offset: offset, frozenAt: frozenAt, idle: model.idle)) { context in
            let clock: String = model.clockText ?? model.clockSince.map {
                ClockPolicy.text(ClockPolicy.elapsed(since: $0, now: context.date, offset: offset, frozenAt: frozenAt))
            } ?? ""
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(model.nowText).font(.system(.subheadline, design: .monospaced)).foregroundStyle(phosphor)
                    Spacer()
                    HStack(spacing: 4) {
                        Text(clock).font(.system(.subheadline, design: .monospaced).monospacedDigit()).foregroundStyle(phosphor)
                        if frozenAt != nil { Image(systemName: "wifi.slash").font(.caption2).foregroundStyle(.secondary) }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(model.clockCaption.lowercased()) \(clock)\(frozenAt != nil ? ", as of the last connection" : "")")
                }
                if !model.dots.isEmpty {
                    HStack(spacing: 3) {
                        Text("CLR").font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary)
                        ForEach(model.dots) { dot in dotView(dot) }
                        Text("REV").font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary)
                    }
                }
                if !model.stopText.isEmpty || model.convergence != nil {
                    HStack {
                        Text(model.stopText).font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary)
                        Spacer()
                        if let word = model.convergence {
                            Text(word).font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(model.convergenceAmber ? .orange : .secondary)
                        }
                    }
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color(red: 0.05, green: 0.07, blue: 0.09)))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(white: 0.2), lineWidth: 1))
            .padding(.horizontal, 12)
        }
    }

    @ViewBuilder private func dotView(_ dot: BoardStripModel.Dot) -> some View {
        let fill: Color = switch dot.state {
        case "done": Color(red: 0.11, green: 0.31, blue: 0.45)
        case "live": model.tone == .live ? Color.accentColor : Color(white: 0.55)
        case "failed": .red
        default: Color(white: 0.12)
        }
        let shape = Capsule().fill(fill).frame(height: dot.state == "live" ? 6 : 4)
            .frame(maxWidth: .infinity)
            .overlay(dot.isStop ? Capsule().stroke(Color.accentColor, lineWidth: 1.5) : nil)
            .shadow(color: dot.state == "live" && model.tone == .live && !reduceMotion ? .accentColor : .clear, radius: 3)
        if dot.tappable, let checkpoint = dot.checkpoint {
            Button { onDot(checkpoint) } label: { shape.frame(minHeight: 22).contentShape(Rectangle()) }
                .buttonStyle(.plain).accessibilityLabel(dot.label)
        } else {
            shape.frame(minHeight: 22).accessibilityLabel(dot.label)
        }
    }
}
