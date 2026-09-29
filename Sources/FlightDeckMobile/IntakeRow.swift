import FleetKit
import SwiftUI

/// One intake in the Sessions list (spec §4.1): a glyph tile, the title, a pill and one fact.
struct IntakeRow: View {
    let summary: WireIntakeSummary
    /// Mac clock − phone clock, the last one an intake screen learned (`FlightControlModel`).
    let offset: TimeInterval
    let frozenAt: Date?

    /// Only a row with a clock redraws on a timer, and on `ClockSchedule`'s: once a second while
    /// the intake works, once a minute once an idle one is past a minute. A plain 1 s periodic
    /// timeline redrew every row every second forever, clock or not.
    var body: some View {
        if let since = summary.clockSince {
            TimelineView(ClockSchedule(since: since, offset: offset, frozenAt: frozenAt,
                                       idle: IntakeRowStyle.clockIsIdle(summary))) { context in
                row(clock: ClockPolicy.text(ClockPolicy.elapsed(since: since, now: context.date, offset: offset, frozenAt: frozenAt)))
            }
        } else {
            row(clock: nil)
        }
    }

    private func row(clock: String?) -> some View {
        let glyph = IntakeRowStyle.glyph(summary)
        return HStack(spacing: 10) {
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

    static func color(_ tone: IntakeTone) -> Color {
        switch tone {
        case .live: .accentColor
        case .attention: .orange
        case .failure: .red
        case .quiet: .secondary
        }
    }
}
