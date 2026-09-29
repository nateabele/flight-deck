import FleetKit
import SwiftUI

/// One intake in the Sessions list (spec §4.1): a glyph tile, the title, a pill and one fact.
struct IntakeRow: View {
    let summary: WireIntakeSummary
    let frozenAt: Date?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let glyph = IntakeRowStyle.glyph(summary)
            let clock = summary.clockSince.map {
                ClockPolicy.text(ClockPolicy.elapsed(since: $0, now: context.date, offset: 0, frozenAt: frozenAt))
            }
            HStack(spacing: 10) {
                Image(systemName: glyph.symbol)
                    .font(.footnote.weight(.bold))
                    .frame(width: 26, height: 26)
                    .foregroundStyle(glyph.tone == .attention ? Color.black : Self.color(glyph.tone))
                    .background(RoundedRectangle(cornerRadius: 7).fill(
                        glyph.tone == .attention ? Color.orange : Self.color(glyph.tone).opacity(0.15)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(summary.title).font(.body).lineLimit(1)
                    HStack(spacing: 6) {
                        Text(IntakeRowStyle.pill(summary).uppercased())
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(Self.color(glyph.tone))
                        if let fact = IntakeRowStyle.fact(summary, clock: clock) {
                            Text(fact).font(.caption.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
        }
    }

    static func color(_ tone: IntakeTone) -> Color {
        switch tone {
        case .live: .accentColor
        case .attention: .orange
        case .failure: .red
        case .quiet: .secondary
        }
    }
}
