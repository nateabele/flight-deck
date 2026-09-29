import AppKit
import IntakeKit
import SwiftUI

/// The COVERAGE cell's card (coverage spec §8): the band word in flap tiles over the cross-check
/// it was read at, then the fidelity's target, a row per reading, the notes, and the engine's
/// suggested action. The same glass and palette as `ConvergenceCard` — the two sit side by side
/// on the LCD and must read as one instrument.
struct CoverageCard: View {
    let model: CoverageCellModel

    private static let lineFont = NSFont.systemFont(ofSize: 12.5)
    private static let maxWidth: CGFloat = 460

    /// The convergence card's width, widened to keep each reading's row on one line: a row is a
    /// run of numbers, and one wrapped at 340 pt left "(estimate)" alone under it, where it read
    /// as a line of its own. Capped, so a long note still wraps rather than stretching the card.
    private var width: CGFloat {
        let widest = model.rows.map(LabelFit.measureWith(Self.lineFont)).max() ?? 0
        return min(Self.maxWidth, max(ConvergenceCard.width, ceil(widest) + 2))
    }

    var body: some View {
        SplitFlapCard(full: model.word, detail: model.caption, tint: model.tone == .amber ? CardTone.amber : nil,
                      accessory: AnyView(accessory))
    }

    private var accessory: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let target = model.targetLine {
                line(target).foregroundStyle(CardTone.ph.opacity(0.9))
            }
            if let empty = model.emptyNote {
                line(empty).foregroundStyle(CardTone.ph2)
            }
            ForEach(Array(model.rows.enumerated()), id: \.offset) { _, row in
                line(row).foregroundStyle(CardTone.ph2)
            }
            ForEach(Array(model.notes.enumerated()), id: \.offset) { _, note in
                line(note).foregroundStyle(CardTone.ph3)
            }
            if let headline = model.actionHeadline {
                Rectangle().fill(CardTone.ph.opacity(0.1)).frame(height: 1).padding(.vertical, 4)
                Text(headline)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(model.tone == .amber ? CardTone.amber : CardTone.ph)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail = model.actionDetail {
                    Text(detail).font(.system(size: 12)).foregroundStyle(CardTone.ph2).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(width: width, alignment: .leading)
        .padding(.top, 4)
    }

    private func line(_ text: String) -> some View {
        Text(text).font(Font(Self.lineFont)).fixedSize(horizontal: false, vertical: true)
    }
}
