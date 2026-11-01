import SwiftUI
import UIKit

/// Why planning halted and what can be done, directly under the board strip. Decisions live in
/// `HaltPanelModel`; this only draws them in the instruments' glass, which adapts to the system
/// appearance, with the signal colour (red for a failure, amber for a pause or stop) on the edge.
struct HaltPanel: View {
    let model: HaltPanelModel
    let offset: TimeInterval
    let frozenAt: Date?
    let onAction: (HaltAction) -> Void
    @State private var outputExpanded = false
    @State private var copied = false

    private var signal: Color { model.isFailure ? Instrument.red : Instrument.amber }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(model.title).font(.subheadline.weight(.semibold)).foregroundStyle(signal)
                Spacer(minLength: 8)
                if model.halt.since != nil {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(model.haltedFor(now: context.date, offset: offset, frozenAt: frozenAt) ?? "")
                            .font(.caption.monospacedDigit()).foregroundStyle(Palette.ph2)
                    }
                }
            }
            if let slot = model.slotLine {
                Text(slot).font(.caption.weight(.medium)).foregroundStyle(Palette.ph)
            }
            Text(model.reason).font(.footnote).foregroundStyle(Instrument.ink).fixedSize(horizontal: false, vertical: true)
            if let todo = model.whatToDo {
                Text(todo).font(.footnote).foregroundStyle(Palette.ph2).fixedSize(horizontal: false, vertical: true)
            }
            if !model.buttons.isEmpty { buttons }
            if let output = model.output { outputSection(output) }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(LinearGradient(colors: [Instrument.cardTop, Instrument.cardBottom], startPoint: .top, endPoint: .bottom))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(signal.opacity(0.55), lineWidth: 1))
        )
        .padding(.horizontal, 16)
        .accessibilityElement(children: .contain)
    }

    private var buttons: some View {
        // Wraps instead of squeezing three long labels into one row at large type sizes.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { buttonViews }
            VStack(alignment: .leading, spacing: 8) { buttonViews }
        }
        .font(.subheadline)
    }

    @ViewBuilder private var buttonViews: some View {
        ForEach(Array(model.buttons.enumerated()), id: \.element.id) { index, button in
            if index == 0 {
                Button { onAction(button.action) } label: { Text(button.title).lineLimit(1) }
                    .buttonStyle(.borderedProminent).tint(Instrument.blue)
                    // The dark blue is light: white on it would not read.
                    .foregroundStyle(Instrument.glassTop)
                    .disabled(!button.enabled)
            } else {
                Button { onAction(button.action) } label: { Text(button.title).lineLimit(1) }
                    .buttonStyle(.bordered).tint(Instrument.blue)
                    .disabled(!button.enabled)
            }
        }
    }

    private func outputSection(_ output: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button { withAnimation { outputExpanded.toggle() } } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.right").font(.caption2.weight(.bold))
                            .rotationEffect(.degrees(outputExpanded ? 90 : 0))
                        Text(outputExpanded ? "Hide agent output" : "Show agent output").font(.caption.weight(.medium))
                    }
                    .frame(minHeight: 44)
                }
                .buttonStyle(.borderless).tint(Instrument.blue)
                Spacer()
                if outputExpanded {
                    Button {
                        UIPasteboard.general.string = output
                        copied = true
                    } label: {
                        Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc").font(.caption.weight(.medium))
                            .frame(minHeight: 44)
                    }
                    .buttonStyle(.borderless).tint(Instrument.blue)
                }
            }
            if outputExpanded {
                ScrollView {
                    Text(output).font(.caption2.monospaced()).foregroundStyle(Palette.ph)
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 220)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Instrument.well))
            }
        }
    }
}
