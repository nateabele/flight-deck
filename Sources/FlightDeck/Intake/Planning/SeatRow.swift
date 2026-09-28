import IntakeKit
import SwiftUI

/// One seat of the round in progress (spec §6), drawn from a `SeatRowModel` and nothing else:
/// who is working, what they are thinking and doing right now, where they have been, and for
/// how long. A finished seat collapses to its outcome.
///
/// Deliberately clockless: the elapsed time and the dwell-held headline/action arrive already
/// settled in `model`, from the ONE 1 Hz timeline its `LiveCard` runs for every row. A timeline
/// per row multiplied the redraws by the seat count, and each row's clock drifted off its
/// neighbours' by however far apart they happened to mount.
struct SeatRow: View {
    let model: SeatRowModel
    /// What a queued row says in place of a headline — the card knows why it is waiting
    /// ("Reading the repo", "Waiting for the agent to start"); the row doesn't.
    var queuedText = "Queued"

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The footprint chips expand to every directory and its count (`footprintAll`) — never
    /// file names: the engine counts files per directory and doesn't record which ones.
    @State private var showsFootprint = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            glyph
            VStack(alignment: .leading, spacing: 3) {
                identityLine
                if finished {
                    outcome
                } else {
                    liveLines
                }
                if let exception = model.exception { exceptionLine(exception) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, finished ? 7 : 9)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityText)
        .accessibilityIdentifier("seat-row-\(model.id)")
    }

    private var finished: Bool { model.glyph == .done || model.glyph == .failed }
    private var running: Bool { model.glyph == .running || model.glyph == .fallback }

    // MARK: - Glyph

    private var glyph: some View {
        let (name, color) = Self.symbol(model.glyph)
        return Image(systemName: name)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(color)
            .frame(width: 18)
            // Replace, not a cross-fade of two unrelated images: queued → running → done reads
            // as one seat changing state. Reduce Motion gets the plain fade.
            .contentTransition(reduceMotion ? .opacity : .symbolEffect(.replace))
            .symbolEffect(.pulse, options: .repeating, isActive: running && !reduceMotion)
            .accessibilityLabel(Self.stateWord(model.glyph))
    }

    /// Colour only for exceptions (spec §2): accent is "live", amber a fallback or a seat that
    /// needs the human, red a failure; a finished seat goes quiet.
    static func symbol(_ glyph: SeatRowModel.Glyph) -> (name: String, color: Color) {
        switch glyph {
        case .queued: ("circle.dashed", .secondary)
        case .running: ("circle.circle.fill", .accentColor)
        case .done: ("checkmark.circle.fill", .secondary)
        case .failed: ("xmark.octagon.fill", .red)
        case .fallback: ("arrow.triangle.swap", .orange)
        case .needsYou: ("hand.raised.fill", .orange)
        }
    }

    static func stateWord(_ glyph: SeatRowModel.Glyph) -> String {
        switch glyph {
        case .queued: "Queued"
        case .running: "Running"
        case .done: "Finished"
        case .failed: "Failed"
        case .fallback: "Running on its fallback model"
        case .needsYou: "Needs you"
        }
    }

    // MARK: - Identity

    private var identityLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(model.role)
                .font(.system(size: 12.5, weight: finished || model.glyph == .queued ? .medium : .semibold))
                .foregroundStyle(finished || model.glyph == .queued ? .secondary : .primary)
                .lineLimit(1)
                .layoutPriority(1)
            Text(model.identity)
                .font(.system(size: 11.5))
                .foregroundStyle(model.glyph == .fallback ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.tertiary))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            if let cost = model.cost {
                // Only ever claude's own final figure (spec §6 "cost only when real").
                Text(cost, format: .currency(code: "USD").precision(.fractionLength(2)))
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
            }
            if model.glyph != .queued {
                Text(BoardModel.clock(model.elapsed))
                    .font(.system(size: 12))
                    .monospacedDigit()
                    .foregroundStyle(finished ? .secondary : .primary)
                    .frame(minWidth: 34, alignment: .trailing)
                    // The clock is not news: VoiceOver reads it on focus, never announces a tick.
                    .accessibilityLabel("Elapsed \(BoardModel.clock(model.elapsed))")
            }
        }
    }

    // MARK: - Live

    @ViewBuilder private var liveLines: some View {
        // The action stands in for a missing headline (SeatRowModel.make); a queued row has
        // neither and says why it is waiting instead.
        if let headline = model.headline {
            Text(headline)
                .font(.system(size: 13.5))
                .foregroundStyle(.primary)
                .lineLimit(2)
        } else {
            Text(queuedText)
                .font(.system(size: 12.5))
                .foregroundStyle(.tertiary)
        }
        if let action = model.action, action != model.headline {
            Text(action)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        if let steps = model.steps {
            Text(steps)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        if !model.footprint.isEmpty || model.contextFraction != nil {
            footRow.padding(.top, 4)
        }
        if showsFootprint { footprintList }
    }

    private var footRow: some View {
        HStack(spacing: 10) {
            if !model.footprint.isEmpty {
                Button { showsFootprint.toggle() } label: {
                    HStack(spacing: 4) {
                        ForEach(model.footprint.indices, id: \.self) { i in
                            chip(model.footprint[i].dir, model.footprint[i].count)
                        }
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(showsFootprint ? 90 : 0))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Files this agent has read or edited, by directory")
                .accessibilityLabel("Files by directory")
                .accessibilityValue(model.footprint.map { "\($0.dir) \($0.count)" }.joined(separator: ", "))
            }
            Spacer(minLength: 0)
            if let fraction = model.contextFraction, let tokens = model.inputTokens, let window = model.contextWindow {
                contextGauge(fraction, tokens: tokens, window: window)
            }
        }
    }

    /// `SeatRowModel.footprint`'s last chip is `+N` (N more directories, its count their files)
    /// when there are more than four — said in words, since "+2 3" read as two numbers.
    private func chip(_ dir: String, _ count: Int) -> some View {
        HStack(spacing: 4) {
            if dir.hasPrefix("+") {
                Text("\(dir) more").foregroundStyle(.secondary)
            } else {
                Text(dir).foregroundStyle(.secondary)
                Text("\(count)").fontWeight(.semibold).monospacedDigit()
            }
        }
        .font(.system(size: 11))
        .lineLimit(1)
        .padding(.horizontal, 7)
        .frame(height: 18)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 5))
    }

    /// Every directory, largest first, two columns — the whole of what the engine recorded.
    private var footprintList: some View {
        let all = model.footprintAll
        let half = (all.count + 1) / 2
        let columns = [Array(all.prefix(half)), Array(all.dropFirst(half))]
        return HStack(alignment: .top, spacing: 24) {
            ForEach(0..<2, id: \.self) { column in
                let items = columns[column]
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(items.indices, id: \.self) { i in
                        HStack(spacing: 8) {
                            Text(items[i].dir).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 8)
                            Text("\(items[i].count)").monospacedDigit()
                        }
                        .frame(maxWidth: 180)
                    }
                }
            }
        }
        .font(.system(size: 11, design: .monospaced))
        .foregroundStyle(.tertiary)
        .padding(.top, 2)
    }

    /// Input tokens against the model's window, both as numbers ("118k of 400k") — shown only
    /// for a model whose window `SeatRowModel` knows (spec §2's determinate-fraction rule). The
    /// numbers, not a percentage: they say how much room is left in the unit the model is sold in.
    private func contextGauge(_ fraction: Double, tokens: Int, window: Int) -> some View {
        let text = "\(Self.tokens(tokens)) of \(Self.tokens(window))"
        return HStack(spacing: 6) {
            Capsule().fill(Color.primary.opacity(0.1))
                .overlay(alignment: .leading) {
                    GeometryReader { g in
                        Capsule().fill(Color.secondary).frame(width: g.size.width * min(max(fraction, 0), 1))
                    }
                }
                .frame(width: 54, height: 4)
            Text(text)
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(.tertiary)
        }
        .help("Input tokens against the model's context window")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Context used")
        .accessibilityValue(text)
    }

    /// "850", "118k", "1M", "1.2M" — whole thousands below a million, since the gauge beside
    /// it already carries the precision.
    static func tokens(_ n: Int) -> String {
        if n < 1_000 { return "\(n)" }
        let k = Int((Double(n) / 1_000).rounded())
        if k < 1_000 { return "\(k)k" }
        let m = Double(n) / 1_000_000
        return m == m.rounded() ? "\(Int(m))M" : String(format: "%.1fM", m)
    }

    // MARK: - Finished

    private var outcome: some View {
        // The result exists only once the round's checkpoint lands (it is read off the round's
        // record); until then a finished seat says what it touched, which the row does know.
        Text(model.result ?? Self.touched(model.footprintAll))
            .font(.system(size: 12.5))
            .foregroundStyle(model.result == nil ? .secondary : .primary)
            .lineLimit(2)
    }

    static func touched(_ all: [(dir: String, count: Int)]) -> String {
        let files = all.reduce(0) { $0 + $1.count }
        guard files > 0 else { return "Finished" }
        return "Finished · \(files) file\(files == 1 ? "" : "s") in \(all.count) director\(all.count == 1 ? "y" : "ies")"
    }

    // MARK: - Exceptions

    private func exceptionLine(_ exception: SeatRowModel.Exception) -> some View {
        let (text, color) = Self.exceptionText(exception)
        return Label {
            Text(text).lineLimit(2)
        } icon: {
            Image(systemName: Self.exceptionSymbol(exception))
        }
        .font(.system(size: 12))
        .foregroundStyle(color)
        .padding(.top, 2)
    }

    static func exceptionText(_ exception: SeatRowModel.Exception) -> (String, Color) {
        switch exception {
        case .quiet(let t): ("Quiet \(BoardModel.clock(t))", .secondary)
        case .stalled(let t, let last):
            ("No output for \(BoardModel.clock(t))" + (last.map { " · last: \($0)" } ?? ""), .orange)
        case .rateLimited(let t): ("Waiting on rate limit · \(BoardModel.clock(t))", .orange)
        case .fallback(let reason): (reason.prefix(1).uppercased() + reason.dropFirst(), .orange)
        case .failed(let reason): ("Failed · \(reason)", .red)
        }
    }

    private static func exceptionSymbol(_ exception: SeatRowModel.Exception) -> String {
        switch exception {
        case .quiet: "moon.zzz"
        case .stalled: "exclamationmark.triangle.fill"
        case .rateLimited: "hourglass"
        case .fallback: "arrow.triangle.swap"
        case .failed: "xmark.octagon.fill"
        }
    }

    // MARK: - Accessibility

    /// Full words, no clock (spec §14): a row announces who and what, never a ticking second.
    private var accessibilityText: String {
        var parts = [model.role, Self.stateWord(model.glyph)]
        if finished { parts.append(model.result ?? Self.touched(model.footprintAll)) }
        else if let headline = model.headline { parts.append(headline) }
        if let exception = model.exception { parts.append(Self.exceptionText(exception).0) }
        return parts.joined(separator: ", ")
    }
}
