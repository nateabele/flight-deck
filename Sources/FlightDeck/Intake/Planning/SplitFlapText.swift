import AppKit
import SwiftUI

/// A board label (spec §5.3): its full name when that fits the measured slot, its code otherwise.
/// A code is focusable, carries a dotted underline, and opens a split-flap card with the full name
/// (and `detail`, e.g. "landed 3:02") on hover or keyboard focus. The card is a `FloatingCard` —
/// its own child panel — so a label inside the tape's ScrollView isn't clipped by it. It opens
/// above the label, after the tooltip-style intent delay (`HoverCardIntent`), so it stays out of
/// the way of a pointer moving along the tape.
///
/// The label's flap plays once per new (surface, text), as `FlapPolicy` decides: it flips in when
/// its value first appears (NOW moving to Refine 3). The policy is keyed on `full`, never on what
/// is displayed, so a resize that swaps the name for its code (or back) is not a new text and does
/// not replay. The card is the exception: it flips its name in on every open (`CardReveal`).
struct SplitFlapText: View {
    let full: String
    let code: String
    let surface: String
    let policy: FlapPolicy
    let font: Font
    let nsFont: NSFont
    /// The card's second line — status and duration. Optional so a bare label needs none.
    var detail: String?
    /// Opens the card without a hover of the label itself: offscreen renders that can't hover,
    /// and a tape slot whose whole column (bar included) is the hover target.
    var showsCardInitially = false
    /// Extra space between characters (the board's letter-spaced captions). Folded into the
    /// fit measurement, or a tracked label would be judged to fit when it doesn't.
    var tracking: CGFloat = 0
    /// Offer the card even when the full name fits: a tape slot's card carries the round's
    /// result, which the label alone never shows.
    var alwaysOffersCard = false
    /// False where an enclosing control owns keyboard focus (a tape slot's column), so the label
    /// isn't a second tab stop inside it.
    var isFocusable = true
    /// False where an enclosing control owns the hover too (the tape slot's column, which opens
    /// this card through `showsCardInitially`): two hover targets nested in one another would
    /// each count as an item, and leaving the label for the column's bar closed the card.
    var ownsHover = true

    @ObservedObject private var intent = HoverCardIntent.shared
    /// This label's key in the app-wide hover intent.
    @State private var hoverID = UUID().uuidString
    @FocusState private var focused: Bool
    /// Focus that a key moved here. Only this opens the card: a click that focused the label, or
    /// the window handing it initial focus, would otherwise pop a card nobody asked for.
    @State private var keyboardFocused = false

    init(full: String, code: String, surface: String, policy: FlapPolicy, font: Font, nsFont: NSFont,
         detail: String? = nil, showsCardInitially: Bool = false, tracking: CGFloat = 0,
         alwaysOffersCard: Bool = false, isFocusable: Bool = true, ownsHover: Bool = true) {
        self.full = full
        self.code = code
        self.surface = surface
        self.policy = policy
        self.font = font
        self.nsFont = nsFont
        self.detail = detail
        self.showsCardInitially = showsCardInitially
        self.tracking = tracking
        self.alwaysOffersCard = alwaysOffersCard
        self.isFocusable = isFocusable
        self.ownsHover = ownsHover
    }

    /// Whether a focus change came from the keyboard — read from the event being handled at the
    /// moment focus moves, since SwiftUI's focus state doesn't say what moved it.
    static func isKeyboardFocus(focused: Bool, event: NSEvent.EventType?) -> Bool {
        focused && event == .keyDown
    }

    /// Width as drawn: the font's advance plus `tracking` after every character.
    private var measure: (String) -> CGFloat {
        let base = LabelFit.measureWith(nsFont)
        let tracking = tracking
        return { base($0) + tracking * CGFloat($0.count) }
    }

    /// One line of `nsFont`: the GeometryReader below would otherwise take all the height offered.
    private var lineHeight: CGFloat { ceil(nsFont.ascender - nsFont.descender + nsFont.leading) }

    var body: some View {
        GeometryReader { geo in
            let shown = LabelFit.choose(full: full, code: code, width: geo.size.width, measure: measure)
            let abbreviated = shown != full
            // A code that still overflows shrinks as a whole. Left to the HStack, each glyph was
            // squeezed and clipped on its own and the row read as broken letters ("EИC").
            let overflow = min(1, geo.size.width / max(1, measure(shown)))
            FlapRow(text: shown, key: full, surface: surface, policy: policy, font: font, tracking: tracking)
                .fixedSize()
                .overlay(alignment: .bottom) {
                    if abbreviated { DottedRule().offset(y: 3) }
                }
                .scaleEffect(overflow, anchor: .leading)
                .background(FloatingCard(
                    isPresented: (abbreviated || alwaysOffersCard)
                        && (intent.shown == hoverID || keyboardFocused || showsCardInitially),
                    card: SplitFlapCard(full: full, detail: detail).fixedSize(),
                    side: .above, onDismiss: { intent.dismiss() }))
                // `.activate`: reachable by Tab under Full Keyboard Access, but never the window's
                // initial focus or a click's focus target.
                .focusable(abbreviated && isFocusable, interactions: .activate)
                .focused($focused)
                .onChange(of: focused) { _, now in
                    keyboardFocused = Self.isKeyboardFocus(focused: now, event: NSApp.currentEvent?.type)
                }
                .onHover { inside in if ownsHover { intent.hover(hoverID, inside) } }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
        .frame(height: lineHeight)
        // Never the code: VoiceOver reads the proper name whatever width the slot has (spec §14).
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(full)
        .accessibilityValue(detail ?? "")
    }
}

/// The board-style card an abbreviated label opens: dark glass, the full name in flap tiles, and
/// the status line in phosphor under it — part of the instrument, never a system tooltip.
struct SplitFlapCard: View {
    let full: String
    let detail: String?
    /// The detail line's colour when it reports an exception (amber for a diverging cycle);
    /// phosphor otherwise.
    var tint: Color?
    /// More of the instrument's say under the detail — the convergence card's numbers and
    /// suggested action. Drawn inside the same glass, so it reads as one card.
    var accessory: AnyView?
    /// Holds the reveal at this many seconds in — offscreen renders of mid-flip frames, which
    /// can't sample a running animation. Nil runs it live.
    var revealAt: TimeInterval?

    static let phosphor = Color(red: 219 / 255, green: 230 / 255, blue: 247 / 255)
    private static let detailFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold)
    private static let detailTracking: CGFloat = 1.2
    private static let maxDetailWidth: CGFloat = 340

    /// The detail's own width when it fits on one line, else the card's wrap width.
    private static func wrapWidth(_ text: String) -> CGFloat? {
        let width = ceil(LabelFit.measureWith(detailFont)(text) + detailTracking * CGFloat(text.count))
        return width > maxDetailWidth ? maxDetailWidth : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CardTiles(text: full.uppercased(), revealAt: revealAt)
            if let detail {
                let text = detail.uppercased()
                Text(text)
                    .font(Font(Self.detailFont))
                    .tracking(Self.detailTracking)
                    .foregroundStyle(tint ?? Self.phosphor.opacity(0.66))
                    // A free-text detail (a failure diagnosis) wraps inside a bounded card rather
                    // than being cut: the card is where its full text is read. The wrap width is
                    // definite, measured with the real font — a flexible frame under the card's
                    // `fixedSize` sized the glass for fewer lines than the text drew.
                    .frame(width: Self.wrapWidth(text), alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let accessory { accessory }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 11)
        .frame(minWidth: 150, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 9)
                .fill(LinearGradient(colors: [Color(red: 0.102, green: 0.118, blue: 0.145),
                                              Color(red: 0.059, green: 0.071, blue: 0.086)],
                                     startPoint: .top, endPoint: .bottom))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Self.phosphor.opacity(0.16), lineWidth: 1))
                .shadow(color: .black.opacity(0.6), radius: 17, y: 14)
        )
    }
}

/// A board label's characters, flipping in one after another the first time its (surface, key)
/// appears.
private struct FlapRow: View {
    let text: String
    let key: String
    let surface: String
    let policy: FlapPolicy
    let font: Font
    let tracking: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The key whose flip this view has run (or skipped). Starts nil so a first appearance
    /// renders hidden until `reveal()` decides.
    @State private var revealed: String?

    private static let stagger = 0.035

    /// Hidden only while a first appearance is waiting to flip in. A pair the policy has already
    /// seen — a re-render, a recreated view, a re-hover — draws in place with no motion at all.
    private var isRevealed: Bool {
        revealed == key || reduceMotion || policy.hasShown(surface: surface, text: key)
    }

    var body: some View {
        let characters = Array(text)
        HStack(spacing: tracking) {
            ForEach(characters.indices, id: \.self) { k in
                Text(String(characters[k])).font(font)
                    .rotation3DEffect(.degrees(isRevealed ? 0 : -90), axis: (x: 1, y: 0, z: 0), perspective: 0.6)
                    .opacity(isRevealed ? 1 : 0.2)
                    // Only the reveal animates, staggered left to right; hiding for a new text is
                    // instant, or the old text would visibly fold away first.
                    .animation(isRevealed ? .easeOut(duration: 0.32).delay(Double(k) * Self.stagger) : nil,
                               value: isRevealed)
            }
        }
        .onAppear(perform: reveal)
        .onChange(of: key) { reveal() }
    }

    /// Consults the policy exactly once per appearance of a key: consulting it from `body` would
    /// burn the flap on a render that may never reach the screen.
    private func reveal() {
        _ = policy.shouldFlap(surface: surface, text: key, reduceMotion: reduceMotion)
        revealed = key
    }

}

/// The card's name in flap tiles, flipping in left to right every time the card opens — the
/// card's host is built afresh per open, so `elapsed` starts at 0 each time. One animated clock
/// for the row, with each tile reading its own eased progress off it (`CardReveal.progress`):
/// the reveal is a pure function of time, so a render can hold it at any instant.
private struct CardTiles: View {
    let text: String
    var revealAt: TimeInterval?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var elapsed: TimeInterval = 0

    var body: some View {
        let characters = Array(text)
        let clock = revealAt ?? (CardReveal.flaps(reduceMotion: reduceMotion) ? elapsed : .infinity)
        HStack(spacing: 2) {
            ForEach(characters.indices, id: \.self) { k in
                tile(characters[k])
                    .modifier(TileFlip(elapsed: clock, index: k, count: characters.count))
            }
        }
        .onAppear {
            let duration = CardReveal.duration(count: characters.count)
            withAnimation(.linear(duration: duration)) { elapsed = duration }
        }
    }

    @ViewBuilder
    private func tile(_ ch: Character) -> some View {
        if ch == " " {
            Color.clear.frame(width: 7, height: 24)
        } else {
            Text(String(ch))
                .font(.system(size: 15, weight: .bold, design: .monospaced))
                .foregroundStyle(Color(red: 0.949, green: 0.965, blue: 0.988))
                .frame(width: 15, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 3).fill(LinearGradient(
                        stops: [.init(color: Color(red: 0.165, green: 0.188, blue: 0.227), location: 0.5),
                                .init(color: Color(red: 0.137, green: 0.157, blue: 0.192), location: 0.5)],
                        startPoint: .top, endPoint: .bottom))
                )
                // The hinge line across the middle of a flap tile.
                .overlay(Rectangle().fill(Color.black.opacity(0.65)).frame(height: 1))
        }
    }
}

/// One tile of `CardTiles`: edge-on and dim until its turn, then falling flat about its hinge.
/// Animatable on the row's clock, so SwiftUI interpolates `elapsed` and every tile follows it.
///
/// The flip is drawn as its head-on projection — the tile's height scaled by cos of its angle
/// about the hinge — not a `rotation3DEffect`: a layer with a 3D transform is dropped by
/// `layer.render(in:)`, so an offscreen render of a mid-flip frame showed blank tiles (and one
/// stray at the window's origin), and the projection is what the eye sees of the rotation anyway.
private struct TileFlip: ViewModifier, Animatable {
    var elapsed: TimeInterval
    let index: Int
    let count: Int

    var animatableData: TimeInterval {
        get { elapsed }
        set { elapsed = newValue }
    }

    func body(content: Content) -> some View {
        let p = CardReveal.progress(index: index, count: count, elapsed: elapsed)
        content
            .scaleEffect(x: 1, y: max(0.001, sin(p * .pi / 2)), anchor: .center)
            .opacity(0.15 + 0.85 * p)
    }
}

/// The subtle dotted underline that marks a label as abbreviated (and so as having a card).
private struct DottedRule: View {
    var body: some View {
        GeometryReader { geo in
            Path { p in
                p.move(to: CGPoint(x: 0, y: 0.75))
                p.addLine(to: CGPoint(x: geo.size.width, y: 0.75))
            }
            .stroke(Color.secondary.opacity(0.6), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [0.1, 3]))
        }
        .frame(height: 1.5)
    }
}
