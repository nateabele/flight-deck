import CoreGraphics
import Foundation

/// The finished-rounds strip's pure parts (spec §3.1): what every card says, which card the
/// detail panel below the strip is open on, where the panel's caret points and how tall it is —
/// pinned by `FinishedRoundsModelTests` rather than by clicking through a run.
///
/// Every card carries the same fields in the same places, whatever kind of round it was: the
/// strip used to draw only what a round happened to have, so a draft card was two lines, a
/// review card four, and a selected one a paragraph taller — the row read as a ragged pile
/// rather than a timeline. A field a round has no value for says `missing` rather than vanishing.
enum FinishedRoundsModel {
    /// What a card shows for a field the round has no value for — never an invented number.
    static let missing = "—"

    /// The worst seat of the round: failed beats fell back beats ran. One glyph per card, where
    /// there used to be one per seat — three for a draft, one for an encode — so a card's width
    /// of glyphs no longer depends on its kind.
    enum Outcome: Equatable { case ran, fellBack, failed, unknown }

    struct Face: Equatable {
        /// The board's stage group, "REFINE".
        var stage: String
        var duration: String
        /// The board's round name, "Refine 1".
        var name: String
        var outcome: Outcome
        var outcomeText: String
        /// What the round produced: "14 changes", or a draft's "3 drafts".
        var work: String
        var lines: String
        /// Agreed · somewhat · declined, numbers only — the panel and `help` spell them out.
        var verdicts: String
        var accessibilityLabel: String
        var help: String
    }

    struct Fact: Equatable {
        var label: String
        var value: String
    }

    /// What the panel shows for the open card: everything the card only hinted at — the whole
    /// note (the selected card used to grow to six lines of it), every seat with its model and
    /// what went wrong, every section, the notes the round took in.
    struct Detail: Equatable {
        var title: String
        var stage: String
        /// Always Duration, Changes, Lines, Verdicts — in that order, for every round.
        var facts: [Fact]
        var note: String?
        var seats: [SlotBadge]
        var sections: [String]
        var notesApplied: [String]
    }

    static func face(_ card: RoundCard) -> Face {
        let duration = card.duration.map(BoardModel.clock)
        let verdicts = shortTally(card)
        let outcome = outcome(card.slots)
        let text = outcomeText(card.slots, outcome)
        let full = [card.name, duration ?? missing, card.changes ?? missing, card.lines ?? missing,
                    card.tally ?? missing, text]
        // VoiceOver never reads a dash: each missing field is said in words, or left out when
        // the words would only repeat the field's name.
        let spoken = [card.name, duration ?? "duration unknown", card.changes, card.lines, card.tally ?? "no verdicts",
                      outcome == .unknown ? nil : text]
        return Face(stage: card.stageTitle, duration: duration ?? missing, name: card.name, outcome: outcome,
                    outcomeText: text, work: card.changes ?? missing, lines: card.lines ?? missing,
                    verdicts: verdicts ?? missing,
                    accessibilityLabel: spoken.compactMap { $0 }.joined(separator: ", "),
                    help: full.filter { $0 != missing }.joined(separator: " · "))
    }

    static func detail(_ card: RoundCard) -> Detail {
        Detail(title: card.name, stage: card.stageTitle,
               facts: [Fact(label: "Duration", value: card.duration.map(BoardModel.clock) ?? missing),
                       Fact(label: "Changes", value: card.changes ?? missing),
                       Fact(label: "Lines", value: card.lines ?? missing),
                       Fact(label: "Verdicts", value: card.tally ?? missing)],
               note: card.note, seats: card.slots, sections: card.allSections, notesApplied: card.notesApplied)
    }

    /// "11 · 2 · 1" from the card's "agreed 11 · somewhat 2 · declined 1": the numbers in the
    /// order the words give them.
    private static func shortTally(_ card: RoundCard) -> String? {
        guard let tally = card.tally else { return nil }
        let numbers = tally.split(separator: " ").filter { $0.allSatisfy(\.isNumber) }
        return numbers.joined(separator: " · ")
    }

    private static func outcome(_ slots: [SlotBadge]) -> Outcome {
        if slots.isEmpty { return .unknown }
        if slots.contains(where: { $0.status == .failed }) { return .failed }
        if slots.contains(where: { $0.status == .substituted }) { return .fellBack }
        return .ran
    }

    private static func outcomeText(_ slots: [SlotBadge], _ outcome: Outcome) -> String {
        let n = slots.count
        let agents = "agent\(n == 1 ? "" : "s")"
        switch outcome {
        case .unknown: return missing
        case .ran: return "\(n) \(agents) ran as asked"
        case .fellBack: return "\(slots.filter { $0.status == .substituted }.count) of \(n) \(agents) fell back"
        case .failed: return "\(slots.filter { $0.status == .failed }.count) of \(n) \(agents) failed"
        }
    }

    // MARK: - Open card

    /// Clicking the open card closes the panel; clicking another switches it in place.
    static func toggled(open: Int?, card: Int) -> Int? {
        open == card ? nil : card
    }

    /// ←/→ while the panel is open: the neighbouring card, stopping at the strip's ends — a wrap
    /// would jump the strip's scroll from one end to the other on a single key. Closed, nothing.
    static func step(open: Int?, by offset: Int, in ids: [Int]) -> Int? {
        guard let open, let index = ids.firstIndex(of: open) else { return nil }
        return ids[min(max(index + offset, 0), ids.count - 1)]
    }

    /// The open card, if it is still on the tape — a rewind or trim can take it off, and the
    /// panel then closes rather than describing a round that is gone.
    static func resolve(open: Int?, in ids: [Int]) -> Int? {
        open.flatMap { ids.contains($0) ? $0 : nil }
    }

    // MARK: - Caret and height

    /// The caret's x on the panel: the open card's centre, kept `margin` clear of the panel's
    /// ends (its rounded corners) — a card scrolled part way out of the strip pins the caret to
    /// that edge, still pointing the way. Centred until the card has been measured.
    static func caretX(cardMidX: CGFloat?, width: CGFloat, margin: CGFloat) -> CGFloat {
        guard let mid = cardMidX else { return width / 2 }
        return min(max(mid, margin), max(margin, width - margin))
    }

    /// The panel is as tall as its content, up to `cap`; past it the content scrolls inside the
    /// panel, so a long note never pushes the plan below it off the page.
    static func panelHeight(content: CGFloat, cap: CGFloat) -> CGFloat {
        min(max(content, 0), cap)
    }

    static func scrolls(content: CGFloat, cap: CGFloat) -> Bool {
        content > cap
    }
}
