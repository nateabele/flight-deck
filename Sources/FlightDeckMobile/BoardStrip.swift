import FleetKit
import SwiftUI

/// The pinned phosphor strip (spec §4.3), with the transport row when the Mac accepts steering.
struct BoardStrip: View {
    let model: BoardStripModel
    let offset: TimeInterval
    let frozenAt: Date?
    let onDot: (Int) -> Void
    /// The transport row; empty (the default) means no row. Every key is off while `frozenAt` is set.
    var keys: [TransportKey] = []
    var onKey: (String) -> Void = { _ in }
    var onDefault: (String) -> Void = { _ in }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var phosphor: Color {
        switch model.tone {
        case .live: Instrument.blue
        case .attention: Instrument.amber
        case .failure: Instrument.red
        case .quiet: Instrument.phosphor
        }
    }

    /// The strip's secondary text. The instrument's own dim phosphor, never `.secondary`: the
    /// glass is its own surface (pale in light, near-black in dark), not the system background,
    /// so a system grey can vanish on it in one appearance or the other.
    private static let dim = Palette.ph2
    /// The hairlines: the glass's rim and the dividers between keys.
    private static let rule = Instrument.lift.opacity(0.14)

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
                        if frozenAt != nil { Image(systemName: "wifi.slash").font(.caption2).foregroundStyle(Self.dim) }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(model.clockCaption.lowercased()) \(clock)\(frozenAt != nil ? ", as of the last connection" : "")")
                }
                if !model.dots.isEmpty {
                    HStack(spacing: 3) {
                        // One line at every size: at AX5 these wrapped a letter per line.
                        Text("CLR").font(.system(.caption2, design: .monospaced)).foregroundStyle(Self.dim).fixedSize()
                        ForEach(model.dots) { dot in dotView(dot) }
                        Text("REV").font(.system(.caption2, design: .monospaced)).foregroundStyle(Self.dim).fixedSize()
                    }
                }
                if !model.stopText.isEmpty || model.convergence != nil {
                    // Side by side when both fit on one line, else stacked: at AX5 a fixed-width
                    // convergence word left the stop line one letter wide.
                    ViewThatFits(in: .horizontal) {
                        HStack {
                            stopLine
                            Spacer()
                            convergenceWord
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            stopLine
                            convergenceWord
                        }
                    }
                }
                if !keys.isEmpty { transportRow }
            }
            // A lost link dims the strip like the list below it: what it shows is as of then.
            // The content only — dimming the glass too let a light background through, turning
            // it grey and the strip's greys invisible on it.
            .opacity(frozenAt == nil ? 1 : 0.5)
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 12).fill(LinearGradient(colors: [Palette.glass0, Palette.glass1], startPoint: .top, endPoint: .bottom)))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Self.rule, lineWidth: 1))
            .padding(.horizontal, 12)
        }
    }

    /// Fixed-height dividers and a row that takes only its ideal height: a bare 1-pt-wide
    /// `Rectangle` is flexible vertically, and inside `IntakeScreen`'s VStack beside a List it
    /// grew the row, and the strip, to half the screen.
    private var transportRow: some View {
        HStack(spacing: 0) {
            ForEach(Array(keys.enumerated()), id: \.element.id) { i, key in
                if i > 0 { Rectangle().fill(Self.rule).frame(width: 1, height: 28) }
                keyView(key)
            }
        }
        .frame(minHeight: 44)
        .fixedSize(horizontal: false, vertical: true)
        .overlay(alignment: .top) { Rectangle().fill(Self.rule).frame(height: 1).offset(y: -4) }
        .padding(.top, 4)
    }

    /// Not a `Button`: a Button swallows the long press that sets the default. Only play keys
    /// carry the long press (and its VoiceOver action) — on Pause or Stop it swallowed a firm
    /// press of half a second, so those act on a tap alone.
    @ViewBuilder private func keyView(_ key: TransportKey) -> some View {
        let live = key.enabled && frozenAt == nil
        let face = VStack(spacing: 2) {
            ZStack(alignment: .top) {
                if let ack = key.ack {
                    Text(ack).font(.system(.caption2, design: .monospaced)).foregroundStyle(phosphor)
                        .lineLimit(1).minimumScaleFactor(0.6)
                } else {
                    keyGlyph(key)
                }
            }
            .frame(height: 20)
            Text(key.caption).font(.system(.caption2, design: .monospaced)).foregroundStyle(Self.dim)
                .lineLimit(1).minimumScaleFactor(0.6)
        }
        .overlay(alignment: .top) {
            if key.isDefault { Circle().fill(Color.accentColor).frame(width: 4, height: 4).offset(y: -5) }
        }
        .frame(maxWidth: .infinity, minHeight: 44)
        // An acknowledgement ("Pausing…") is the answer to the maintainer's own press: drawn at full
        // strength though the key is off, or it read as disabled rather than working.
        .opacity(live || (key.ack != nil && frozenAt == nil) ? 1 : 0.4)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(key.ack ?? key.accessibilityLabel + (key.isDefault ? ", default" : ""))
        .accessibilityAddTraits(.isButton)
        if live && key.canBeDefault {
            face
                .onTapGesture { onKey(key.id) }
                .onLongPressGesture(minimumDuration: 0.5) {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    onDefault(key.id)
                }
                .accessibilityAction { onKey(key.id) }
                .accessibilityAction(named: "Make default") { onDefault(key.id) }
        } else if live {
            face
                .onTapGesture { onKey(key.id) }
                .accessibilityAction { onKey(key.id) }
        } else {
            // VoiceOver says "dimmed" for an off key rather than offering a button that does nothing.
            face.disabled(true)
        }
    }

    /// To-review is the forward glyph with a diamond beside it, as on the Mac's control bar.
    @ViewBuilder private func keyGlyph(_ key: TransportKey) -> some View {
        if key.id == "toReview" {
            HStack(spacing: 2) {
                Image(systemName: key.symbol).font(.subheadline)
                Image(systemName: "diamond.fill").font(.system(size: 6))
            }.foregroundStyle(phosphor)
        } else {
            Image(systemName: key.symbol).font(.subheadline).foregroundStyle(phosphor)
        }
    }

    private var stopLine: some View {
        Text(model.stopText).font(.system(.caption2, design: .monospaced)).foregroundStyle(Self.dim)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var convergenceWord: some View {
        if let word = model.convergence {
            Text(word).font(.system(.caption2, design: .monospaced))
                .foregroundStyle(model.convergenceAmber ? Instrument.amber : Self.dim)
                .fixedSize()
        }
    }

    @ViewBuilder private func dotView(_ dot: BoardStripModel.Dot) -> some View {
        let fill: Color = switch dot.state {
        case "done": Instrument.blue.opacity(0.45)
        case "live": model.tone == .live ? Color.accentColor : Palette.ph2
        case "failed": Instrument.red
        default: Instrument.lift.opacity(0.12)
        }
        let shape = Capsule().fill(fill).frame(height: dot.state == "live" ? 6 : 4)
            .frame(maxWidth: .infinity)
            .overlay(dot.isStop ? Capsule().stroke(Color.accentColor, lineWidth: 1.5) : nil)
            .shadow(color: dot.state == "live" && model.tone == .live && frozenAt == nil && !reduceMotion ? .accentColor : .clear, radius: 3)
        if dot.tappable, let checkpoint = dot.checkpoint {
            Button { onDot(checkpoint) } label: { shape.frame(minHeight: 22).contentShape(Rectangle()) }
                .buttonStyle(.plain).accessibilityLabel(dot.label)
        } else {
            shape.frame(minHeight: 22).accessibilityLabel(dot.label)
        }
    }
}
