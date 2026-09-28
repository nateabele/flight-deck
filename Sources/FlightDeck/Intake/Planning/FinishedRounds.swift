import IntakeKit
import SwiftUI

/// The rounds already on the tape, as a strip of cards (spec §3.1 "finished rounds as cards"),
/// and the detail panel a card opens below it — the Finder Quick Look strip's shape: every card
/// one size and saying the same things (`FinishedRoundsModel.Face`), and one full-width panel
/// with a caret on its top edge pointing up at the card it describes.
///
/// A card click opens the panel (and shows the round in the plan below, as a card click always
/// has); the open card again, or Esc, closes it; another card switches the panel in place. The
/// panel is its content's height up to `Metrics.cap`, the content scrolling inside past that;
/// switching cards animates the height from one round's content to the next, the caret sliding
/// across in the same beat.
///
/// Equatable, and `.equatable()` where `LiveCard` draws it: the card redraws on its 1 Hz clock,
/// and every tick re-running this body re-measured the panel and re-laid the strip for rounds
/// that cannot change while they are on screen. The closures are left out of `==` — they only
/// ever write the same two bindings.
struct FinishedRounds: View, Equatable {
    let cards: [RoundCard]
    /// The checkpoint the plan shows (the head when following it) — the card highlighted while
    /// no panel is open.
    let planSelection: Int?
    /// The card whose panel is open (`IntakeDetailView.openRound`); nil for none.
    let open: Int?
    /// Shows a round in the plan — `LiveCard` applies the head-follows rule.
    let select: (Int) -> Void
    let setOpen: (Int?) -> Void

    static func == (a: Self, b: Self) -> Bool {
        a.cards == b.cards && a.planSelection == b.planSelection && a.open == b.open
    }

    private enum Metrics {
        /// As wide as the strip's edge fade, so a card at either end sits clear of it.
        static let fade: CGFloat = 24
        static let cardWidth: CGFloat = 184
        static let cap: CGFloat = 360
        static let radius: CGFloat = 10
        static let caret = CGSize(width: 22, height: 9)
        /// Wide enough to set the note beside the seats rather than above them.
        static let twoColumns: CGFloat = 760
        /// Where the caret's centre may go: clear of the panel's rounded corners.
        static var caretMargin: CGFloat { radius + caret.width / 2 + 2 }
    }

    private static let space = "finished-rounds"

    /// Each card's centre in the section's space — moves with the strip's horizontal scroll, so
    /// the caret keeps pointing at its card while the strip scrolls under it.
    @State private var mids: [Int: CGFloat] = [:]
    /// The open round's panel content as last laid out — the height the panel animates to. Set
    /// inside `withAnimation`, so the live card and the plan below move with the panel rather than
    /// jumping to where it will end up. Held across a switch until the new round reports: reading
    /// the new round's height before it has one collapsed the panel to nothing mid-switch.
    @State private var contentHeight: CGFloat = 0
    /// The section's width, which decides the panel's columns. Measured rather than left to
    /// `ViewThatFits`: that compares ideal widths, and a paragraph's ideal is one unwrapped line,
    /// so the two-column layout never fit at any pane width.
    @State private var width: CGFloat = 0
    @FocusState private var focused: Int?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var openCard: RoundCard? {
        FinishedRoundsModel.resolve(open: open, in: cards.map(\.checkpointID)).flatMap { id in
            cards.first { $0.checkpointID == id }
        }
    }

    var body: some View {
        let openCard = openCard
        let highlighted = openCard?.checkpointID ?? planSelection
        VStack(alignment: .leading, spacing: 6) {
            Text("Finished rounds")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .padding(.horizontal, 12)
            strip(highlighted: highlighted, open: openCard?.checkpointID)
            if let openCard {
                panel(openCard)
                    .transition(.opacity)
            }
        }
        .coordinateSpace(name: Self.space)
        .background(GeometryReader { geo in
            Color.clear.onAppear { width = geo.size.width }.onChange(of: geo.size.width) { _, w in width = w }
        })
        .onPreferenceChange(CardMidKey.self) { mids = $0 }
        .onPreferenceChange(DetailHeightKey.self) { [open = openCard?.checkpointID] heights in
            guard let open, let height = heights[open], abs(height - contentHeight) > 0.5 else { return }
            withAnimation(reduceMotion ? nil : Self.motion) { contentHeight = height }
        }
        // Closed, the next open grows from nothing again.
        .onChange(of: openCard == nil) { _, closed in if closed { contentHeight = 0 } }
    }

    private static let motion = Animation.smooth(duration: 0.3)

    // MARK: - Strip

    private func strip(highlighted: Int?, open: Int?) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 8) {
                    ForEach(cards) { card in
                        cardView(card, highlighted: card.checkpointID == highlighted, open: card.checkpointID == open)
                            .id(card.checkpointID)
                    }
                }
                .padding(.horizontal, Metrics.fade)
                // Room for the selected card's focus ring and stroke, which the scroll view clips.
                .padding(.vertical, 3)
            }
            // Soft edges: scrolled to the newest round, the strip cuts an older card at its
            // leading edge, and a hard cut read as a clipping bug rather than "more this way".
            .mask(HStack(spacing: 0) {
                LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing).frame(width: Metrics.fade)
                Color.black
                LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing).frame(width: Metrics.fade)
            })
            // The newest round is the one worth seeing; a long run's first cards are history —
            // unless a panel is open, whose caret needs its card on screen to point at.
            .onAppear { proxy.scrollTo(open ?? cards.last?.checkpointID, anchor: open == nil ? .trailing : nil) }
            .onChange(of: cards.last?.checkpointID) { _, id in proxy.scrollTo(id, anchor: .trailing) }
            // An arrow key can open a card that is scrolled out of the strip: bring it in, by
            // the least scroll, so the caret has a card to point at.
            .onChange(of: open) { _, id in
                guard let id else { return }
                withAnimation(reduceMotion ? nil : Self.motion) { proxy.scrollTo(id) }
            }
        }
    }

    private func activate(_ id: Int) {
        let next = FinishedRoundsModel.toggled(open: open, card: id)
        withAnimation(reduceMotion ? nil : Self.motion) { setOpen(next) }
        if let next { select(next) }
    }

    private func close() {
        withAnimation(reduceMotion ? nil : Self.motion) { setOpen(nil) }
    }

    /// ←/→ with the panel open: the neighbouring round, focus following it.
    private func step(_ offset: Int) -> KeyPress.Result {
        guard let next = FinishedRoundsModel.step(open: open, by: offset, in: cards.map(\.checkpointID)),
              next != open else { return open == nil ? .ignored : .handled }
        withAnimation(reduceMotion ? nil : Self.motion) { setOpen(next) }
        select(next)
        focused = next
        return .handled
    }

    private func cardView(_ card: RoundCard, highlighted: Bool, open: Bool) -> some View {
        let face = FinishedRoundsModel.face(card)
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(face.stage)
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 6)
                Text(face.duration)
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }
            HStack(spacing: 6) {
                Text(face.name).font(.system(size: 12.5, weight: .semibold))
                Spacer(minLength: 6)
                outcomeGlyph(face)
            }
            HStack(spacing: 6) {
                Text(face.work)
                Spacer(minLength: 6)
                Text(face.lines)
            }
            .font(.system(size: 12))
            .monospacedDigit()
            .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Text("Verdicts").foregroundStyle(.tertiary)
                Spacer(minLength: 6)
                Text(face.verdicts).monospacedDigit().foregroundStyle(.secondary)
            }
            .font(.system(size: 11.5))
        }
        // One line a row, every row on every card: the cards are one size by construction.
        .lineLimit(1)
        .frame(width: Metrics.cardWidth, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(highlighted ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.045),
                    in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .strokeBorder(highlighted ? Color.accentColor.opacity(0.8) : Color.primary.opacity(0.08)))
        .background(GeometryReader { geo in
            Color.clear.preference(key: CardMidKey.self, value: [card.checkpointID: geo.frame(in: .named(Self.space)).midX])
        })
        .contentShape(Rectangle())
        .onTapGesture { activate(card.checkpointID) }
        .help(face.help)
        // Keyboard and VoiceOver reach a card as a click does (spec §14).
        .focusable(interactions: .activate)
        .focused($focused, equals: card.checkpointID)
        .onKeyPress(keys: [.return, .space]) { _ in activate(card.checkpointID); return .handled }
        .onKeyPress(.leftArrow) { step(-1) }
        .onKeyPress(.rightArrow) { step(1) }
        .onExitCommand(perform: self.open == nil ? nil : close)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(face.accessibilityLabel)
        .accessibilityValue(open ? "Expanded" : "Collapsed")
        .accessibilityHint(open ? "Closes the round's details" : "Shows the round's details below the rounds")
        .accessibilityAddTraits(highlighted ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { activate(card.checkpointID) }
        .accessibilityIdentifier("round-card-\(card.checkpointID)")
    }

    @ViewBuilder
    private func outcomeGlyph(_ face: FinishedRoundsModel.Face) -> some View {
        switch face.outcome {
        case .unknown:
            Text(FinishedRoundsModel.missing).font(.system(size: 11)).foregroundStyle(.tertiary)
        case .ran, .fellBack, .failed:
            Self.statusSymbol(face.outcome == .ran ? .ok : face.outcome == .fellBack ? .substituted : .failed)
        }
    }

    static func statusSymbol(_ status: SlotStatus) -> some View {
        let (symbol, color): (String, Color) = switch status {
        case .ok: ("checkmark.circle.fill", .secondary)
        case .substituted: ("arrow.triangle.swap", .orange)
        case .failed: ("xmark.octagon.fill", .red)
        }
        return Image(systemName: symbol)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(color)
    }

    // MARK: - Panel

    private func panel(_ card: RoundCard) -> some View {
        let id = card.checkpointID
        let height = FinishedRoundsModel.panelHeight(content: contentHeight, cap: Metrics.cap)
        return ScrollView(.vertical) {
            ZStack(alignment: .topLeading) {
                RoundDetailView(detail: FinishedRoundsModel.detail(card), wide: width >= Metrics.twoColumns, close: close)
                    .background(GeometryReader { geo in
                        Color.clear.preference(key: DetailHeightKey.self, value: [id: geo.size.height])
                    })
                    .id(id)
                    .transition(.opacity)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .scrollIndicators(FinishedRoundsModel.scrolls(content: contentHeight, cap: Metrics.cap) ? .automatic : .never)
        // The frame, not a re-layout: the new round's content is laid out at once at its own
        // height inside the scroll view, and only the window onto it grows or shrinks.
        .frame(height: height)
        .padding(.top, Metrics.caret.height)
        .background(CaretPanel(caretX: mids[id] ?? .nan, radius: Metrics.radius, caret: Metrics.caret,
                               margin: Metrics.caretMargin)
            .fill(Color.primary.opacity(0.06)))
        .overlay(CaretPanel(caretX: mids[id] ?? .nan, radius: Metrics.radius, caret: Metrics.caret,
                            margin: Metrics.caretMargin)
            .stroke(Color.primary.opacity(0.14)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(card.name) details")
        .accessibilityIdentifier("round-detail-panel")
    }
}

/// The panel's outline: a rounded rectangle whose top edge rises into a caret at `caretX`
/// (clamped by `FinishedRoundsModel.caretX`). The caret's x is the shape's animatable data, so
/// a switch slides it to the new card in the same animation as the height; a strip scroll moves
/// it with no animation, staying under its card. `.nan` is "not measured yet": centred.
private struct CaretPanel: Shape {
    var caretX: CGFloat
    let radius: CGFloat
    let caret: CGSize
    let margin: CGFloat

    var animatableData: CGFloat {
        get { caretX }
        set { caretX = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let body = CGRect(x: rect.minX, y: rect.minY + caret.height, width: rect.width, height: rect.height - caret.height)
        let x = rect.minX + FinishedRoundsModel.caretX(cardMidX: caretX.isNaN ? nil : caretX, width: rect.width, margin: margin)
        let half = caret.width / 2
        var path = Path()
        path.move(to: CGPoint(x: body.minX + radius, y: body.minY))
        path.addLine(to: CGPoint(x: x - half, y: body.minY))
        // Softened at the tip: a razor point read as a glitch at 1x.
        path.addQuadCurve(to: CGPoint(x: x, y: rect.minY + 0.5), control: CGPoint(x: x - half / 2, y: body.minY))
        path.addQuadCurve(to: CGPoint(x: x + half, y: body.minY), control: CGPoint(x: x + half / 2, y: body.minY))
        path.addLine(to: CGPoint(x: body.maxX - radius, y: body.minY))
        path.addArc(tangent1End: CGPoint(x: body.maxX, y: body.minY), tangent2End: CGPoint(x: body.maxX, y: body.maxY), radius: radius)
        path.addArc(tangent1End: CGPoint(x: body.maxX, y: body.maxY), tangent2End: CGPoint(x: body.minX, y: body.maxY), radius: radius)
        path.addArc(tangent1End: CGPoint(x: body.minX, y: body.maxY), tangent2End: CGPoint(x: body.minX, y: body.minY), radius: radius)
        path.addArc(tangent1End: CGPoint(x: body.minX, y: body.minY), tangent2End: CGPoint(x: body.maxX, y: body.minY), radius: radius)
        path.closeSubpath()
        return path
    }
}

/// One round's details, laid out across the panel: the note beside the seats and sections when
/// the pane is wide enough for two columns (a note set across 1000 pt is a hard read), one under
/// the other when it isn't.
private struct RoundDetailView: View {
    let detail: FinishedRoundsModel.Detail
    let wide: Bool
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(detail.title).font(.system(size: 13, weight: .semibold))
                // "Refine 2 · REFINE" says which group; "Encode · ENCODE" only says it twice.
                if detail.stage != detail.title.uppercased() {
                    Text(detail.stage)
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(0.6)
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 8)
                Button(action: close) {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Close (Esc)")
                .accessibilityLabel("Close details")
                .accessibilityIdentifier("round-detail-close")
            }
            facts
            if wide {
                HStack(alignment: .top, spacing: 28) {
                    VStack(alignment: .leading, spacing: 12) { note; notesApplied }
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    VStack(alignment: .leading, spacing: 12) { seats; sections }
                        .frame(width: 300, alignment: .topLeading)
                }
            } else {
                VStack(alignment: .leading, spacing: 12) { note; seats; sections; notesApplied }
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var facts: some View {
        HStack(alignment: .top, spacing: 28) {
            ForEach(detail.facts, id: \.label) { fact in
                VStack(alignment: .leading, spacing: 2) {
                    heading(fact.label)
                    Text(fact.value)
                        .font(.system(size: 12.5))
                        .monospacedDigit()
                        .foregroundStyle(fact.value == FinishedRoundsModel.missing ? .tertiary : .primary)
                        .textSelection(.enabled)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    @ViewBuilder
    private var note: some View {
        VStack(alignment: .leading, spacing: 4) {
            heading("Note")
            if let note = detail.note {
                Text(note)
                    .font(.system(size: 12.5))
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            } else {
                Text("No note recorded.").font(.system(size: 12.5)).foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder
    private var notesApplied: some View {
        if !detail.notesApplied.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                heading("Your notes this round")
                ForEach(Array(detail.notesApplied.enumerated()), id: \.offset) { _, text in
                    Label { Text(text).fixedSize(horizontal: false, vertical: true) } icon: {
                        Image(systemName: "note.text").foregroundStyle(.tertiary)
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var seats: some View {
        VStack(alignment: .leading, spacing: 5) {
            heading("Agents")
            if detail.seats.isEmpty {
                Text(FinishedRoundsModel.missing).font(.system(size: 12)).foregroundStyle(.tertiary)
            }
            ForEach(Array(detail.seats.enumerated()), id: \.offset) { _, seat in
                VStack(alignment: .leading, spacing: 1) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        FinishedRounds.statusSymbol(seat.status)
                        Text(seat.label).font(.system(size: 12, weight: .medium))
                        Text(seat.model).font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    if let diagnosis = seat.diagnosis {
                        Text(diagnosis)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.leading, 18)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    private var sections: some View {
        VStack(alignment: .leading, spacing: 4) {
            heading("Sections changed")
            Text(detail.sections.isEmpty ? FinishedRoundsModel.missing : detail.sections.joined(separator: " · "))
                .font(.system(size: 12))
                .foregroundStyle(detail.sections.isEmpty ? .tertiary : .secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func heading(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.6)
            .textCase(.uppercase)
            .foregroundStyle(.tertiary)
    }
}

private struct CardMidKey: PreferenceKey {
    static let defaultValue: [Int: CGFloat] = [:]
    static func reduce(value: inout [Int: CGFloat], nextValue: () -> [Int: CGFloat]) {
        value.merge(nextValue()) { _, new in new }
    }
}

private struct DetailHeightKey: PreferenceKey {
    static let defaultValue: [Int: CGFloat] = [:]
    static func reduce(value: inout [Int: CGFloat], nextValue: () -> [Int: CGFloat]) {
        value.merge(nextValue()) { _, new in new }
    }
}
