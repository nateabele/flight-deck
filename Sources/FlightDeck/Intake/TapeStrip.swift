import IntakeKit
import SwiftUI

/// The collapsed tape (spec §8.3): one track, a tick per round — tall for a major checkpoint
/// (a stage's end), short for a minor one — stage names over their columns, and the yellow
/// playhead on the head checkpoint. Marks are spaced evenly by round, not by time; see
/// `StageMarker`.
struct TapeStrip: View {
    let model: ShapingModel

    private static let height: CGFloat = 64
    private static let trackY: CGFloat = 30

    var body: some View {
        GeometryReader { geo in
            let markers = model.stages
            let step = markers.isEmpty ? 0 : geo.size.width / CGFloat(markers.count)
            let x = { (i: Int) -> CGFloat in step * (CGFloat(i) + 0.5) }

            ZStack(alignment: .topLeading) {
                Capsule()
                    .fill(Color.secondary.opacity(0.25))
                    .frame(width: geo.size.width, height: 4)
                    .offset(y: Self.trackY - 2)
                if let head = model.playheadIndex {
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: x(head), height: 4)
                        .offset(y: Self.trackY - 2)
                }

                ForEach(columns(markers), id: \.first) { column in
                    let center = (x(column.first) + x(column.last)) / 2
                    Text(ShapingModel.stageTitle(markers[column.first].stage))
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .fixedSize()
                        .position(x: center, y: 6)
                    if column.first > 0 {
                        // Dashed rule between stage columns, as in the mockup.
                        Path { p in
                            p.move(to: CGPoint(x: x(column.first) - step / 2, y: 0))
                            p.addLine(to: CGPoint(x: x(column.first) - step / 2, y: Self.height))
                        }
                        .stroke(Color.secondary.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    }
                }

                ForEach(markers) { marker in
                    tick(marker).position(x: x(marker.order), y: Self.trackY)
                    Text(marker.label)
                        .font(.system(size: 9.5))
                        .foregroundStyle(marker.done || marker.inProgress ? .primary : .secondary)
                        .fixedSize()
                        .position(x: x(marker.order), y: Self.trackY + 22)
                }

                if let head = model.playheadIndex {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.yellow)
                        .frame(width: 12, height: 20)
                        .shadow(color: .yellow.opacity(0.4), radius: 3)
                        .position(x: x(head), y: Self.trackY)
                }
            }
        }
        .frame(height: Self.height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Tape: " + model.stages.map { "\($0.label) \($0.done ? "done" : "pending")" }.joined(separator: ", "))
        .accessibilityIdentifier("tape-strip")
    }

    @ViewBuilder
    private func tick(_ marker: StageMarker) -> some View {
        let color: Color = marker.done ? .accentColor : .secondary.opacity(0.6)
        if marker.inProgress {
            // The round running now: hollow, in the accent colour, so it reads as "filling in".
            RoundedRectangle(cornerRadius: 2)
                .strokeBorder(Color.accentColor, lineWidth: 2)
                .frame(width: marker.major ? 8 : 6, height: marker.major ? 28 : 16)
        } else {
            RoundedRectangle(cornerRadius: marker.major ? 2 : 1)
                .fill(color)
                .frame(width: marker.major ? 4 : 2, height: marker.major ? 28 : 16)
        }
    }

    /// Runs of consecutive markers sharing a stage column (fresh eyes and dedup share FINAL).
    private struct Column { var first: Int; var last: Int }

    private func columns(_ markers: [StageMarker]) -> [Column] {
        var result: [Column] = []
        for m in markers {
            let title = ShapingModel.stageTitle(m.stage)
            if let last = result.last, ShapingModel.stageTitle(markers[last.first].stage) == title {
                result[result.count - 1].last = m.order
            } else {
                result.append(Column(first: m.order, last: m.order))
            }
        }
        return result
    }
}
