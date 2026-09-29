import AppKit
import IntakeKit
import SwiftUI

/// The selected seat in the detail pane's inspector (spec §3): what its row has no room for —
/// every directory it touched, its tokens, and where its run lives on disk. Static on purpose:
/// the row above keeps the ticking clock, so the inspector never adds a second one.
struct SeatInspector: View {
    let model: SeatRowModel
    /// The seat's own activity, for the output tokens the row model doesn't carry.
    let activity: SeatActivity?
    let runDirectory: URL

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    let (symbol, color) = SeatRow.symbol(model.glyph)
                    Image(systemName: symbol).foregroundStyle(color)
                    // Sentence case, not `.capitalized`: "cross-check agent" is a phrase, and
                    // title-casing it would read "Cross-Check Agent".
                    Text(UIText.sentenceCase(model.role)).font(.headline)
                }
                Text(model.identity).foregroundStyle(.secondary)
                Text(SeatRow.stateWord(model.glyph)).font(.callout).foregroundStyle(.secondary)
            }

            if let headline = model.result ?? model.headline {
                Text(headline)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

            section("Tokens") {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                    row("Input", activity?.inputTokens.map(SeatRow.tokens) ?? "—")
                    row("Output", activity?.outputTokens.map(SeatRow.tokens) ?? "—")
                    if let used = model.inputTokens, let window = model.contextWindow {
                        row("Context", "\(SeatRow.tokens(used)) of \(SeatRow.tokens(window))")
                    }
                    if let cost = model.cost {
                        row("Billed", cost.formatted(.currency(code: "USD").precision(.fractionLength(2))))
                    }
                }
            }

            section("Files Touched") {
                if model.footprintAll.isEmpty {
                    Text("None yet").foregroundStyle(.secondary)
                } else {
                    // Directories and their counts — the engine counts files per directory and
                    // never records which ones, so this is the whole of what there is to list.
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                        ForEach(model.footprintAll, id: \.dir) { entry in
                            GridRow {
                                Text(entry.dir).lineLimit(1).truncationMode(.middle)
                                Text("\(entry.count) file\(entry.count == 1 ? "" : "s")")
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                                    .gridColumnAlignment(.trailing)
                            }
                        }
                    }
                }
            }

            section("Run Directory") {
                Text(runDirectory.path)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([runDirectory])
                }
                .disabled(!FileManager.default.fileExists(atPath: runDirectory.path))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("inspector-seat")
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            content()
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).monospacedDigit()
        }
    }
}

/// The inspector's resting state when there is nothing selected to show.
struct InspectorPlaceholder: View {
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 6) {
            Text(title).font(.headline).foregroundStyle(.secondary)
            Text(message)
                .font(.callout)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 40)
        .frame(maxWidth: .infinity)
    }
}
