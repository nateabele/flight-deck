import AppKit
import IntakeKit
import SwiftUI

/// The planning run as a departures board (spec §5, mock M2): the board fields on top — NOW with
/// its state chip, IN THE AIR / PAUSED FOR, STOPS AT, CALLING AT — over a tape of rounds from
/// `DEP · CLR` to `ARR · REV`, all in the same dark glass as the control bar's LCD.
///
/// Everything it says comes from `BoardModel`; this view only lays it out. The parent owns the
/// 1 Hz clock and re-derives the model each tick, so the live slot and IN THE AIR count up
/// without this view keeping a timer of its own.
struct DeparturesBoard: View {
    let model: BoardModel
    let policy: FlapPolicy
    /// The play button being hovered in the control bar. The model already folds it into STOPS
    /// AT ("WOULD STOP"); the board uses it for that field's colour and glyph.
    @Binding var preview: PlayMode?
    let onSelect: (Int) -> Void
    let onExtend: (Stage) -> Void
    /// The bracket's −: takes an unstarted round off the cycle (`TapeCommand.trim`).
    let onTrim: (Stage) -> Void
    /// Opens one slot's card without a hover — for offscreen renders, which can't hover.
    var openCardSlotID: String?
    /// Drawn in the board's glass under the tape: the convergence heatmap (spec §8.3), whose
    /// columns line up under the tape's slots via `slotColumns`.
    var disclosure: AnyView?

    init(model: BoardModel, policy: FlapPolicy, preview: Binding<PlayMode?>,
         onSelect: @escaping (Int) -> Void, onExtend: @escaping (Stage) -> Void,
         onTrim: @escaping (Stage) -> Void = { _ in }, openCardSlotID: String? = nil, disclosure: AnyView? = nil) {
        self.model = model
        self.policy = policy
        self._preview = preview
        self.onSelect = onSelect
        self.onExtend = onExtend
        self.onTrim = onTrim
        self.openCardSlotID = openCardSlotID
        self.disclosure = disclosure
    }

    /// Where each of `slotIDs` sits across a board `width` points wide, measured from the board's
    /// leading edge exactly as the tape lays its slots out — so what is drawn under the tape can
    /// line up with it. Nil when the tape is wider than the board and scrolls: nothing under it
    /// can follow a scroll, so the caller lays itself out instead of lining up with a moving tape.
    static func slotColumns(_ model: BoardModel, slotIDs: [String], width: CGFloat) -> [ClosedRange<CGFloat>]? {
        let available = width - 2 * Style.inset
        let widths = model.slotWidths(available: available, measure: Style.slotMeasure)
        guard widths.reduce(0, +) <= available + 0.5 else { return nil }
        var edges: [String: ClosedRange<CGFloat>] = [:]
        var x = Style.inset
        for (slot, w) in zip(model.slots, widths) {
            edges[slot.id] = x...(x + w)
            x += w
        }
        let found = slotIDs.compactMap { edges[$0] }
        return found.count == slotIDs.count ? found : nil
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Which slot's card is open by hover: the app-wide tooltip rules (`HoverIntent`) — a
    /// pointer passing along the tape opens nothing, resting on a slot does, and the next slot's
    /// opens at once while one is up.
    @ObservedObject private var intent = HoverCardIntent.shared
    /// Prefixes this board's slot ids in the intent, so another board showing the same slot id
    /// doesn't open its card too.
    @State private var hoverToken = UUID().uuidString
    @FocusState private var focusedSlot: String?
    /// The slot a key moved focus to — the only focus that opens its card (see
    /// `SplitFlapText.isKeyboardFocus`).
    @State private var keyboardSlot: String?

    var body: some View {
        VStack(spacing: 0) {
            fields
            tape
            HStack {
                Text("DEP · CLR")
                Spacer()
                Text("ARR · REV")
            }
            .font(Style.caption)
            .tracking(Style.captionTracking)
            .foregroundStyle(Palette.ph3)
            .padding(.horizontal, Style.inset)
            .padding(.bottom, 12)
            .accessibilityHidden(true)
            if let disclosure {
                Rectangle().fill(Palette.ph.opacity(0.08)).frame(height: 1)
                disclosure
            }
        }
        .background(Glass())
    }

    // MARK: - Board fields

    private var fields: some View {
        GeometryReader { geo in
            let unit = geo.size.width / 4.75
            HStack(spacing: 0) {
                cell(model.now, width: unit * 1.45, divider: true) { _ in
                    Text(model.now.label)
                } value: {
                    HStack(spacing: 10) {
                        // A failure's diagnosis is free text with no short form: two lines under
                        // NOW, and the whole of it on NOW's card.
                        flap(model.now.value, code: model.now.valueCode, surface: "board.now", font: Style.nowFont,
                             detail: model.now.shortDetail == nil ? model.now.detail : nil)
                            .foregroundStyle(.white)
                        chip
                    }
                }
                cell(model.inTheAir, width: unit * 0.8, divider: true) { _ in
                    // Only the label flaps (IN THE AIR ↔ PAUSED FOR ↔ HALTED FOR); the value
                    // below is a clock ticking every second and never flaps — see `flapTexts`.
                    SplitFlapText(full: model.inTheAir.label, code: model.inTheAir.shortLabel, surface: "board.inTheAir",
                                  policy: policy, font: Style.caption, nsFont: Style.captionNS, tracking: Style.captionTracking)
                } value: {
                    Text(model.inTheAir.value)
                        .font(.system(size: 28, weight: .semibold, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(model.nowChip == "FAILED" ? Palette.red : .white)
                        .lineLimit(1)
                        // Shrink rather than truncate: "34:…" hides the minutes that matter.
                        .minimumScaleFactor(0.5)
                }
                cell(model.stopsAt, width: unit * 1.05, divider: true) { caption in
                    HStack(spacing: 5) {
                        if let preview {
                            Image(systemName: Self.glyph(preview)).foregroundStyle(Palette.blue2)
                        }
                        Text(caption(preview == nil ? 0 : Style.glyphWidth))
                    }
                } value: {
                    flap(model.stopsAt.value, code: model.stopsAt.valueCode, surface: "board.stopsAt", font: Style.stopFont)
                        .foregroundStyle(preview == nil ? Palette.blue2 : .white)
                }
                cell(model.callingAt, width: unit * 1.45, divider: false) { caption in
                    Text(caption(0))
                } value: {
                    flap(model.callingAt.value, code: model.callingAt.valueCode, surface: "board.callingAt", font: Style.callingFont)
                        .foregroundStyle(model.callingAt.valueCode == nil ? Palette.ph3 : Palette.ph)
                }
            }
        }
        .frame(height: Style.fieldsHeight)
        .background(LinearGradient(colors: [.white.opacity(0.025), .clear], startPoint: .top, endPoint: .bottom))
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.ph.opacity(0.08)).frame(height: 1) }
    }

    /// One board field. `label` is handed the field's caption as a function of the room other
    /// marks take from it, so it can say "STOPS AT" or "STOPS" by measurement. The detail line
    /// is likewise the sentence when it fits and the coded form ("since ENC") when it doesn't —
    /// never a sentence cut mid-word. Either form wraps onto a second line rather than truncating.
    private func cell(_ field: BoardField, width: CGFloat, divider: Bool,
                      @ViewBuilder label: ((CGFloat) -> String) -> some View,
                      @ViewBuilder value: () -> some View) -> some View {
        let inner = width - 2 * Style.inset
        let caption = { (taken: CGFloat) in
            LabelFit.choose(full: field.label, code: field.shortLabel, width: inner - taken, padding: 0, measure: Style.captionMeasure)
        }
        let detail = field.detail.map {
            LabelFit.choose(full: $0, code: field.shortDetail ?? $0, width: inner, padding: 0, measure: Style.detailMeasure)
        }
        return VStack(alignment: .leading, spacing: 0) {
            label(caption)
                .font(Style.caption)
                .tracking(Style.captionTracking)
                .foregroundStyle(Palette.ph3)
                .frame(height: 14)
            value()
                .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                .padding(.top, 8)
            if let detail {
                Text(detail)
                    .font(Font(Style.detailNS))
                    .foregroundStyle(model.nowChip == "FAILED" && field.detail == model.now.detail ? Palette.red : Palette.ph2)
                    // Two lines, wrapped at word boundaries: in the narrowest cells even the coded
                    // form ("since RF2 failed") needs them, and a tail cut would split a word.
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 5)
            }
        }
        .padding(.horizontal, Style.inset)
        .padding(.top, 14)
        .frame(width: width, height: Style.fieldsHeight, alignment: .topLeading)
        .overlay(alignment: .trailing) {
            if divider { Rectangle().fill(Palette.ph.opacity(0.07)).frame(width: 1) }
        }
        .accessibilityElement(children: .combine)
    }

    /// A board value as a split-flap label no wider than its full name, so the chip beside NOW
    /// sits against the name instead of being pushed to the cell's far edge. `detail` puts a
    /// card on the value even when its name fits — how NOW carries a diagnosis too long to show.
    private func flap(_ full: String, code: String?, surface: String, font: NSFont, detail: String? = nil) -> some View {
        SplitFlapText(full: full, code: code ?? full, surface: surface, policy: policy, font: Font(font), nsFont: font,
                      detail: detail, alwaysOffersCard: detail != nil)
            .frame(maxWidth: LabelFit.fitWidth(full: full, measure: LabelFit.measureWith(font)))
    }

    /// Colour only for exceptions (spec §2): red for a failure, amber for "needs you", a light
    /// fill for a hold, an outline for everything that is simply on course.
    private var chip: some View {
        let (fill, text): (Color, Color) = switch model.nowChip {
        case "FAILED": (Palette.red.opacity(0.85), .white)
        case "NEEDS YOU": (Palette.amber, Color(red: 0.106, green: 0.071, blue: 0.016))
        case "PAUSED", "STOPPED": (Palette.ph, Color(white: 0.07))
        default: (.clear, Palette.ph)
        }
        return Text(model.nowChip)
            .font(.system(size: 10.5, weight: .bold, design: .monospaced))
            .tracking(1)
            .foregroundStyle(text)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 5).fill(fill))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(fill == .clear ? Palette.ph3 : .clear, lineWidth: 1))
            .fixedSize()
    }

    private static func glyph(_ mode: PlayMode) -> String {
        switch mode {
        case .step: "forward.end.fill"
        case .nextMajor: "forward.end.alt.fill"
        case .toReview: "forward.fill"
        }
    }

    // MARK: - Tape

    private var followID: String? { model.followSlotID }

    private var tape: some View {
        GeometryReader { geo in
            let available = geo.size.width - 2 * Style.inset
            let widths = model.slotWidths(available: available, measure: Style.slotMeasure)
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    HStack(spacing: 0) {
                        ForEach(Array(model.slots.enumerated()), id: \.element.id) { i, slot in
                            column(slot, index: i, width: widths[i]).id(slot.id)
                        }
                    }
                    .overlay(alignment: .topLeading) { brackets(widths) }
                    .padding(.horizontal, Style.inset)
                    // A scroll slides the hovered slot out from under a pointer that never
                    // moved, so no hover-exit arrives: forget the hover, or its card would reopen.
                    .background(ScrollWatcher { intent.dismiss() })
                }
                .scrollIndicators(.never)
                // Follows the live slot only when WHICH slot it is changes, never on a tick or
                // a re-render: a user who scrolled away to read an old round isn't yanked back
                // every second, and the tape catches up the moment a new round takes off.
                .onAppear { if let id = followID { proxy.scrollTo(id, anchor: .center) } }
                .onChange(of: focusedSlot) { _, id in
                    keyboardSlot = SplitFlapText.isKeyboardFocus(focused: id != nil, event: NSApp.currentEvent?.type) ? id : nil
                }
                .onChange(of: followID) { _, id in
                    guard let id else { return }
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.35)) { proxy.scrollTo(id, anchor: .center) }
                }
            }
        }
        .frame(height: Style.bracketRow + Style.labelRow + 6 + Style.barHeight + Style.tickRow)
        .padding(.top, 10)
    }

    private func column(_ slot: TapeSlot, index i: Int, width: CGFloat) -> some View {
        let slots = model.slots
        let apart = { (a: TapeSlot, b: TapeSlot) in a.group == nil || a.group != b.group }
        let lead: CGFloat = i > 0 && apart(slots[i - 1], slot) ? 6 : 2
        let trail: CGFloat = i < slots.count - 1 && apart(slot, slots[i + 1]) ? 6 : 2
        let isLast = i == slots.count - 1
        return VStack(spacing: 0) {
            Color.clear.frame(height: Style.bracketRow)
            label(slot, width: width - 6).frame(height: Style.labelRow)
            Color.clear.frame(height: 6)
            bar(slot).padding(.leading, lead).padding(.trailing, trail).frame(height: Style.barHeight)
            ticks(slot, last: isLast).frame(height: Style.tickRow)
        }
        .frame(width: width)
        .background(alignment: .top) {
            if slot.state == .selected {
                VStack(spacing: 0) {
                    Rectangle().fill(Color.accentColor).frame(height: 2)
                    Rectangle().fill(Color.accentColor.opacity(0.16))
                }
                .frame(height: Style.labelRow + 6 + Style.barHeight + 10)
                .padding(.top, Style.bracketRow - 5)
            }
        }
        .overlay(alignment: .topTrailing) {
            // A major checkpoint's gate: a rule from the label row down through the bar.
            if slot.major && !isLast {
                Rectangle().fill(Palette.ph.opacity(slot.state == .future ? 0.14 : 0.34))
                    .frame(width: 1, height: Style.labelRow + 6 + Style.barHeight)
                    .padding(.top, Style.bracketRow)
                    .offset(x: 0.5)
            }
        }
        .contentShape(Rectangle())
        // Keyboard access (spec §14): Tab reaches each slot under Full Keyboard Access, with the
        // system focus ring; Return or Space selects a landed one, as a click does.
        .focusable(interactions: .activate)
        .focused($focusedSlot, equals: slot.id)
        .onKeyPress(keys: [.return, .space]) { _ in
            guard let id = slot.checkpointID else { return .ignored }
            onSelect(id)
            return .handled
        }
        .onHover { intent.hover(hoverKey(slot), $0) }
        .onTapGesture { if let id = slot.checkpointID { onSelect(id) } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(model.accessibilityLabel(for: slot))
        .accessibilityAddTraits(slot.checkpointID == nil ? [] : .isButton)
        .accessibilityAction { if let id = slot.checkpointID { onSelect(id) } }
    }

    /// The slot's name (its code when the name doesn't fit), plus the marks around it: the pause
    /// glyph where the run is held, the live round's ticking clock, the flag for notes.
    private func label(_ slot: TapeSlot, width: CGFloat) -> some View {
        let paused = slot.id == model.pausedAtSlotID
        let glyphs: CGFloat = (paused ? 12 : 0) + (slot.flagged ? 12 : 0)
        let full = LabelFit.fitWidth(full: slot.name, measure: Style.slotMeasure)
        let code = LabelFit.fitWidth(full: slot.code, measure: Style.slotMeasure)
        // The live round's clock rides beside its name only while even the code still fits next
        // to it; a narrower slot drops it rather than drawing the two over each other — the same
        // count is in IN THE AIR and on the slot's card.
        let clock = (slot.state == .live ? slot.duration.map(BoardModel.clock) : nil)
            .flatMap { code + Style.clockMeasure($0) + 5 <= width - glyphs ? $0 : nil }
        // What the marks take from the slot, measured with their own fonts, so the fit decision
        // is made against the room actually left for the name.
        let room = max(0, width - glyphs - (clock.map { Style.clockMeasure($0) + 5 } ?? 0))
        return HStack(spacing: 4) {
            if paused { Image(systemName: "pause.fill").font(.system(size: 8, weight: .bold)) }
            SplitFlapText(full: slot.name, code: slot.code, surface: slot.id, policy: policy,
                          font: Font(Style.slotNS), nsFont: Style.slotNS, detail: model.cardDetail(for: slot),
                          showsCardInitially: intent.shown == hoverKey(slot) || keyboardSlot == slot.id
                              || openCardSlotID == slot.id,
                          alwaysOffersCard: true, isFocusable: false, ownsHover: false)
                // Exactly the width it will draw at, so the HStack can centre a code too.
                .frame(width: full <= room ? full : min(room, code))
            if let clock {
                Text(clock).font(Font(Style.clockNS)).monospacedDigit().foregroundStyle(.white)
            }
            if slot.flagged {
                Image(systemName: "flag.fill").font(.system(size: 8)).foregroundStyle(Palette.amber)
            }
        }
        .foregroundStyle(labelColor(slot))
        .frame(maxWidth: .infinity)
    }

    private func hoverKey(_ slot: TapeSlot) -> String { "\(hoverToken)/\(slot.id)" }

    private func labelColor(_ slot: TapeSlot) -> Color {
        switch slot.state {
        case .live: .white
        case .failed: Palette.red
        case .selected: Palette.blue2
        case _ where slot.id == model.stopSlotID: Palette.blue2
        case .done: slot.major ? Palette.ph : Palette.ph2
        case .future: slot.major ? Palette.ph2 : Palette.ph3
        }
    }

    @ViewBuilder
    private func bar(_ slot: TapeSlot) -> some View {
        let shape = RoundedRectangle(cornerRadius: 6)
        let isReview = slot.id == "review"
        let text = slot.state == .live ? nil : slot.duration.map(BoardModel.clock) ?? (isReview ? "REVIEW" : nil)
        ZStack {
            switch slot.state {
            case .done where isReview:
                shape.fill(Palette.amber)
            case .done:
                shape.fill(LinearGradient(colors: [Palette.ph.opacity(slot.major ? 0.28 : 0.2), Palette.ph.opacity(slot.major ? 0.18 : 0.13)],
                                          startPoint: .top, endPoint: .bottom))
            case .selected:
                shape.fill(Color.accentColor)
            case .live:
                shape.fill(Color.accentColor.opacity(0.13))
                    .overlay(shape.strokeBorder(Color.accentColor.opacity(0.5), lineWidth: 1))
                    .overlay(alignment: .leading) { Playhead() }
            case .failed:
                shape.fill(Palette.red.opacity(0.18))
                    .overlay(Stripes().fill(Palette.red.opacity(0.45)).clipShape(shape))
                    .overlay(shape.strokeBorder(Palette.red, lineWidth: 1.25))
                    .shadow(color: Palette.red.opacity(0.35), radius: 7)
            case .future:
                shape.strokeBorder(Palette.ph.opacity(0.13), lineWidth: 1)
            }
            if let text {
                let label = Text(text)
                    .font(.system(size: 12, weight: isReview ? .bold : .semibold, design: .monospaced))
                    .tracking(isReview ? 1 : 0)
                    .monospacedDigit()
                    .foregroundStyle(barTextColor(slot, isReview: isReview))
                    .lineLimit(1)
                    .padding(.horizontal, 3)
                if isReview {
                    // The word only repeats the label above it, so a bar too narrow for it goes
                    // without rather than reading "REVI…".
                    ViewThatFits(in: .horizontal) { label.fixedSize(); Color.clear }
                } else {
                    label.minimumScaleFactor(0.7)
                }
            }
        }
        .overlay {
            if slot.id == model.stopSlotID {
                shape.strokeBorder(Color.accentColor, lineWidth: 1.75).shadow(color: Color.accentColor.opacity(0.45), radius: 8)
            } else if slot.id == model.pausedAtSlotID {
                shape.strokeBorder(.white.opacity(0.85), lineWidth: 1.5)
            }
        }
    }

    private func barTextColor(_ slot: TapeSlot, isReview: Bool) -> Color {
        switch slot.state {
        case .done where isReview: Color(red: 0.106, green: 0.071, blue: 0.016)
        case .selected, .failed: .white
        case .done: Palette.ph
        case .live, .future: slot.id == model.stopSlotID ? Palette.blue2 : Palette.ph3
        }
    }

    /// The ruler under a slot: quarter ticks across it, and at its end a tick that's tall for a
    /// major checkpoint and short for a minor one, brighter once the round has landed.
    private func ticks(_ slot: TapeSlot, last: Bool) -> some View {
        let landed = slot.state == .done || slot.state == .selected
        return Canvas { context, size in
            let top: CGFloat = 4
            for q in 1..<4 {
                let x = size.width * CGFloat(q) / 4
                context.fill(Path(CGRect(x: x - 0.5, y: top, width: 1, height: 5)), with: .color(Palette.ph.opacity(0.12)))
            }
            let height: CGFloat = slot.major ? 20 : 11
            let x = last ? size.width - 1 : size.width - 0.5
            context.fill(Path(CGRect(x: x, y: top, width: 1, height: height)),
                         with: .color(Palette.ph.opacity(landed ? 0.4 : 0.16)))
        }
        .accessibilityHidden(true)
    }

    /// "REFINE ×3" brackets over each cycle — "REFINE 2 OF 3" while one of its rounds is in
    /// flight or failed — with the + that extends it while the head hasn't moved past it, and
    /// beside it the − that takes back a round the runner hasn't started. Neither asks first: an
    /// unrun round costs nothing, and the other handle undoes it.
    private func brackets(_ widths: [CGFloat]) -> some View {
        let edges = widths.reduce(into: [CGFloat(0)]) { $0.append($0.last! + $1) }
        let y: CGFloat = 8
        return ZStack(alignment: .topLeading) {
            ForEach(model.groups, id: \.name) { group in
                let x0 = edges[group.range.lowerBound] + 6
                let x1 = edges[group.range.upperBound + 1] - 6
                let handles = [group.trimmable, group.extendable].compactMap { $0 }.count
                // A one-round cycle is narrower than two handles: they spill left over the bracket
                // row of the one-off stage before it (never bracketed), and the line shrinks to a tick.
                let end = max(x0, x1 - CGFloat(handles) * Self.handleStride)
                Path { p in
                    p.move(to: CGPoint(x: x0, y: y + 6))
                    p.addLine(to: CGPoint(x: x0, y: y))
                    p.addLine(to: CGPoint(x: end, y: y))
                    p.addLine(to: CGPoint(x: end, y: y + 6))
                }
                .stroke(Palette.ph.opacity(0.3), lineWidth: 1)
                // Between the bracket's start and its handles: the title shortens before a
                // handle is ever drawn over it (`BoardModel.bracketTitles`), and goes last.
                Text(Self.fittedBracketTitle(model.bracketTitles(group), width: end - x0 - 18))
                    .font(Font(Self.bracketNS))
                    .tracking(Self.bracketTracking)
                    .foregroundStyle(bracketIsActive(group) ? Palette.ph : Palette.ph3)
                    .fixedSize()
                    .padding(.horizontal, 6)
                    .background(Palette.glass0)
                    .offset(x: x0 + 6, y: y - 7)
                if let stage = group.trimmable {
                    handle("minus", help: "Remove a \(group.name.capitalized) round") { onTrim(stage) }
                        .offset(x: x1 - 16 - (group.extendable == nil ? 0 : Self.handleStride), y: y - 8)
                }
                if let stage = group.extendable {
                    handle("plus", help: "Add another \(group.name.capitalized) round",
                           label: "Extend \(group.name.capitalized)") { onExtend(stage) }
                        .offset(x: x1 - 16, y: y - 8)
                }
            }
        }
        .frame(width: edges.last ?? 0, height: Style.bracketRow, alignment: .topLeading)
    }

    /// A bracket handle's 16 pt box plus the gap to its neighbour (or to the bracket's end).
    private static let handleStride: CGFloat = 22

    /// A bracket's + or −: one look, one hit target, reachable by keyboard like any button.
    /// VoiceOver hears `label`, in words — the help text unless the handle has its own.
    private func handle(_ symbol: String, help: String, label: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Palette.ph2)
                .frame(width: 16, height: 16)
                .background(RoundedRectangle(cornerRadius: 4).strokeBorder(Palette.ph3, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(label ?? help)
    }

    private static let bracketNS = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .semibold)
    private static let bracketTracking: CGFloat = 1.2

    /// The first of `candidates` (longest first, `BoardModel.bracketTitles`) that fits `width`,
    /// or nothing — the title's own 6 pt padding either side is already taken out by the caller.
    static func fittedBracketTitle(_ candidates: [String], width: CGFloat) -> String {
        let measure = { (s: String) in LabelFit.measureWith(bracketNS)(s) + bracketTracking * CGFloat(s.count) }
        return candidates.first { measure($0) <= width } ?? ""
    }

    private func bracketIsActive(_ group: TapeGroup) -> Bool {
        model.slots[group.range].contains { $0.state == .live || $0.state == .failed }
    }
}

// MARK: - Pieces

/// The board's fonts and rows, as `NSFont` where a label is measured (spec §5.3) so the fit
/// decision and the drawn text use the same metrics.
private enum Style {
    static let inset: CGFloat = 18
    static let bracketRow: CGFloat = 22
    static let labelRow: CGFloat = 20
    static let barHeight: CGFloat = 30
    static let tickRow: CGFloat = 28

    static let captionNS = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .bold)
    static let caption = Font(captionNS)
    static let captionTracking: CGFloat = 1.5
    static let captionMeasure: (String) -> CGFloat = { LabelFit.measureWith(captionNS)($0) + captionTracking * CGFloat($0.count) }
    static let glyphWidth: CGFloat = 19
    static let detailNS = NSFont.systemFont(ofSize: 12.5)
    static let detailMeasure = LabelFit.measureWith(detailNS)
    /// Tall enough for NOW's two-line diagnosis under a 32 pt value.
    static let fieldsHeight: CGFloat = 116
    static let nowFont = NSFont.systemFont(ofSize: 24, weight: .bold)
    static let stopFont = NSFont.systemFont(ofSize: 21, weight: .bold)
    static let callingFont = NSFont.systemFont(ofSize: 17, weight: .medium)
    static let slotNS = NSFont.monospacedSystemFont(ofSize: 13, weight: .semibold)
    static let slotMeasure = LabelFit.measureWith(slotNS)
    static let clockNS = NSFont.monospacedSystemFont(ofSize: 12, weight: .bold)
    static let clockMeasure = LabelFit.measureWith(clockNS)
}

/// The instrument's phosphor-on-glass palette, shared with the split-flap card.
private enum Palette {
    static let ph = SplitFlapCard.phosphor
    static let ph2 = ph.opacity(0.66)
    static let ph3 = ph.opacity(0.4)
    static let blue2 = Color(red: 124 / 255, green: 188 / 255, blue: 1)
    static let red = Color(red: 1, green: 107 / 255, blue: 97 / 255)
    static let amber = Color(red: 1, green: 179 / 255, blue: 64 / 255)
    static let glass0 = Color(red: 0x13 / 255, green: 0x16 / 255, blue: 0x1b / 255)
    static let glass1 = Color(red: 0x0c / 255, green: 0x0e / 255, blue: 0x11 / 255)
}

/// Dark glass: a top-lit gradient, a hairline rim, and faint scan lines.
private struct Glass: View {
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12)
        shape.fill(LinearGradient(colors: [Palette.glass0, Palette.glass1], startPoint: .top, endPoint: .bottom))
            .overlay(
                Canvas { context, size in
                    for y in stride(from: 0, to: size.height, by: 3) {
                        context.fill(Path(CGRect(x: 0, y: y, width: size.width, height: 1)), with: .color(Palette.ph.opacity(0.02)))
                    }
                }
                .clipShape(shape)
            )
            .overlay(shape.strokeBorder(.white.opacity(0.08), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.35), radius: 1, y: 0.5)
    }
}

/// The live round's playhead: a lit run from the leg's start to a glowing dot. It marks that the
/// round is flying, not how far along it is — there is no honest fraction to draw (spec §2).
private struct Playhead: View {
    var body: some View {
        ZStack(alignment: .trailing) {
            RoundedRectangle(cornerRadius: 6)
                .fill(LinearGradient(colors: [Color.accentColor.opacity(0.35), Color.accentColor], startPoint: .leading, endPoint: .trailing))
                .frame(width: 22)
                .shadow(color: Color.accentColor.opacity(0.7), radius: 8)
            Circle()
                .fill(.white)
                .frame(width: 13, height: 13)
                .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: 3).padding(-3))
                .shadow(color: Color.accentColor.opacity(0.8), radius: 8)
                .offset(x: 6)
        }
    }
}

/// The failed slot's diagonal hazard stripes.
private struct Stripes: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        var x = rect.minX - rect.height
        while x < rect.maxX {
            path.move(to: CGPoint(x: x, y: rect.maxY))
            path.addLine(to: CGPoint(x: x + rect.height, y: rect.minY))
            path.addLine(to: CGPoint(x: x + rect.height + 5, y: rect.minY))
            path.addLine(to: CGPoint(x: x + 5, y: rect.maxY))
            path.closeSubpath()
            x += 10
        }
        return path
    }
}
