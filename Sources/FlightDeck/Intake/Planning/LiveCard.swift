import AppKit
import IntakeKit
import SwiftUI

/// The stage body of an intake while agents work (spec §3 item 3, §3.1): who is working, on
/// what, and for how long — triage's one seat, or a shaping round's control bar, board, seat
/// rows and the rounds already finished.
///
/// The control bar and the departures board come in as view closures, not types: they are
/// built separately (Tasks 6 and 7), and the card only decides where they sit — and hands
/// them the card's `now`, so their ELAPSED and IN THE AIR tick on the same second as the rows.
///
/// One 1 Hz `TimelineView` drives every clock in the card — the bar's, the board's, the rows'
/// — and every row's `DwellScheduler`; it stops while the window is occluded and while nothing
/// on the card is counting (spec §2 — a hidden window spent a redraw per second per intake on
/// clocks nobody could see, and one timeline per part drifted the parts apart).
struct LiveCard: View {
    fileprivate enum Kind {
        case triage(activity: SeatActivity?)
        case shaping(tape: Tape, seats: SeatFiles, editConflict: String?, selectedRound: Binding<Int?>,
                     controlBar: (Date) -> AnyView, board: (Date) -> AnyView)
    }

    fileprivate let intake: Intake
    fileprivate let kind: Kind
    fileprivate let pending: PendingStart?

    @State private var visible = true
    /// Not observed: the schedulers are consulted from inside the timeline's content on every
    /// tick (their contract — `offer` each tick with the current values), and the returned
    /// values are what the rows draw. Observing them as well would redraw the card a second
    /// time for every tick that released a hold.
    @State private var dwell = DwellBank()

    /// `activity` is `IntakeService.triageActivity(_:)`; `pending` its `pending[id]`.
    static func triage(intake: Intake, activity: SeatActivity?, pending: PendingStart?) -> LiveCard {
        LiveCard(intake: intake, kind: .triage(activity: activity), pending: pending)
    }

    /// - Parameters:
    ///   - activities/records/results: `IntakeService.seatActivities[id]` / `runRecords[id]` /
    ///     `seatResults[id]` — the round in progress's seats only.
    ///   - editConflict: the banner text for plan edits a round couldn't carry forward — Task 11
    ///     supplies it; nil hides the banner.
    ///   - selectedRound: the checkpoint the plan viewer shows; nil follows the head.
    static func shaping(intake: Intake, tape: Tape, activities: [String: SeatActivity], records: [String: RunRecord],
                        results: [String: SeatResult] = [:], pending: PendingStart?, editConflict: String? = nil,
                        selectedRound: Binding<Int?> = .constant(nil),
                        controlBar: @escaping (Date) -> AnyView, board: @escaping (Date) -> AnyView) -> LiveCard {
        LiveCard(intake: intake,
                 kind: .shaping(tape: tape, seats: SeatFiles(activities: activities, records: records, results: results),
                                editConflict: editConflict, selectedRound: selectedRound,
                                controlBar: controlBar, board: board),
                 pending: pending)
    }

    var body: some View {
        TimelineView(LiveClockSchedule(ticking: visible && isLive)) { context in
            content(now: context.date)
        }
        .padding(14)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.08)))
        .background(WindowVisibilityReader(visible: $visible))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(isTriage ? "live-card-triage" : "live-card-shaping")
    }

    private func content(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            switch kind {
            case .triage:
                seatSection(now: now)
            case .shaping(let tape, _, let editConflict, let selectedRound, let controlBar, let board):
                controlBar(now)
                board(now)
                let model = ShapingModel(intake: intake, tape: tape)
                if let banner = model.pauseBanner {
                    Self.banner(symbol: "exclamationmark.triangle.fill", title: banner.title, detail: banner.action,
                                identifier: "shaping-pause-banner")
                }
                if let editConflict {
                    Self.banner(symbol: "arrow.triangle.merge", title: editConflict, detail: nil,
                                identifier: "shaping-edit-conflict-banner")
                }
                if !tape.pendingNotes.isEmpty {
                    let n = tape.pendingNotes.count
                    Label("\(n) note\(n == 1 ? "" : "s") queued for the next round", systemImage: "note.text")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if hasSeats(tape) {
                    seatSection(now: now)
                }
                if !model.roundCards.isEmpty {
                    FinishedRounds(cards: model.roundCards, tape: tape, selection: selectedRound)
                }
            }
        }
    }

    private var isTriage: Bool { if case .triage = kind { true } else { false } }

    /// Anything on the card still counting: a start not yet heard from, triage mid-turn, or any
    /// shaping tape short of review — the board's PAUSED FOR / HALTED FOR count up while the
    /// runner is idle too. A settled card ticking over frozen clocks would only burn redraws.
    private var isLive: Bool {
        if pending != nil { return true }
        switch kind {
        case .triage(let activity): return intake.state == .triaging && activity?.finished != true
        case .shaping(let tape, _, _, _, _, _): return tape.status != .reachedReview
        }
    }

    private func hasSeats(_ tape: Tape) -> Bool { tape.roundInProgress != nil || pendingRound != nil }

    private var pendingRound: PlannedRound? {
        if case .round(let round)? = pending?.kind { return round }
        return nil
    }

    // MARK: - Seats

    private func seatSection(now: Date) -> some View {
        let seats = dwell.settle(liveSeats(now: now))
        return VStack(alignment: .leading, spacing: 6) {
            sectionHeader(seats: seats, now: now)
            VStack(spacing: 0) {
                ForEach(Array(seats.enumerated()), id: \.element.id) { index, seat in
                    if index > 0 { Divider().padding(.leading, 40) }
                    SeatRow(model: seat.model, queuedText: queuedText(now: now))
                }
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: seats.map(\.model.glyph))
        }
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private func sectionHeader(seats: [LiveSeat], now: Date) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(sectionTitle)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            if pending == nil, seats.count > 1 {
                // Seats done out of seats: the one progress fraction a round honestly has.
                let done = seats.filter { $0.model.glyph == .done }.count
                Text("\(done) of \(seats.count) seats done")
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 8)
            if let pending {
                // No dead moments (spec §3.1): the click's own clock, from 0:00, until the work
                // shows a sign of life.
                Text(BoardModel.clock(max(0, now.timeIntervalSince(pending.since))))
                    .font(.system(size: 12))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Waiting \(BoardModel.clock(max(0, now.timeIntervalSince(pending.since))))")
            }
        }
        .padding(.horizontal, 12)
    }

    private var sectionTitle: String {
        switch kind {
        case .triage: return "Triage"
        case .shaping(let tape, _, _, _, _, _):
            guard let round = tape.roundInProgress ?? pendingRound else { return "Seats" }
            return BoardModel.name(stage: round.stage, round: round.round)
        }
    }

    /// What a queued row says: a start that has been silent for `IntakeService.queuedAfter`
    /// stops promising it is starting (the service flips `queued` on its own tick; the local
    /// clock gets there first so the words change on the second, not up to a tick late).
    private func queuedText(now: Date) -> String {
        if let pending, pending.queued || now.timeIntervalSince(pending.since) >= IntakeService.queuedAfter {
            return "Waiting for the agent to start"
        }
        if isTriage { return "Reading the repo" }
        return pending != nil ? "Starting" : "Queued"
    }

    private func liveSeats(now: Date) -> [LiveSeat] {
        switch kind {
        case .triage(let activity):
            // A pending start's activity is the PREVIOUS turn's, still on disk until the new
            // turn writes — drawing it would show a finished seat under a "starting" clock.
            let current = pending == nil ? activity : nil
            var model = SeatRowModel.make(run: "triage", slot: nil, requested: triageSlot(activity: current),
                                          activity: current, record: nil, roundRecord: nil, now: now)
            // Spec §3.1: "Reading the repo" until the first event says anything more specific.
            if model.glyph == .running, model.headline == nil { model.headline = "Reading the repo" }
            return [LiveSeat(id: "triage", model: model)]
        case .shaping(let tape, let seats, _, _, _, _):
            guard let round = tape.roundInProgress ?? pendingRound else { return [] }
            return LiveSeats.rows(round: round, config: intake.roundConfig, seats: pending == nil ? seats : SeatFiles(),
                                  now: now)
        }
    }

    /// The triage turn's own model, once a resumed turn has recorded it — only when it matches
    /// the harness actually streaming, since `make` reads a harness mismatch as a fallback and
    /// triage has none.
    private func triageSlot(activity: SeatActivity?) -> Slot? {
        guard let session = intake.triage, activity == nil || activity?.harness == session.harness else { return nil }
        return Slot(ModelChoice(harness: session.harness, model: session.model, effort: session.effort))
    }

    // MARK: - Banners

    /// Amber, the only colour a banner gets (spec §2: amber is attention).
    static func banner(symbol: String, title: String, detail: String?, identifier: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.semibold))
                if let detail { Text(detail).font(.callout).foregroundStyle(.secondary) }
            }
            .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(identifier)
    }
}

// MARK: - Seat list

/// What the service has read of one round's `runs/`, keyed by run name — bundled because every
/// consumer takes all three together.
struct SeatFiles {
    var activities: [String: SeatActivity] = [:]
    var records: [String: RunRecord] = [:]
    var results: [String: SeatResult] = [:]
}

/// One row of the seat list, keyed by the seat — not the run: a fallback or correction attempt
/// is a new `runs/` directory, and keying by it re-created the row mid-round, so the glyph's
/// Replace transition and the chips' expansion reset at exactly the moment worth watching.
struct LiveSeat: Identifiable {
    let id: String
    var model: SeatRowModel
}

/// Which seats a round has, in the order the engine runs them, and each one's latest run —
/// pure, so the seat list is pinned by tests rather than by a running round.
enum LiveSeats {
    /// The round's seats as the engine names them (`RoundExecutor.runName`:
    /// `<stage>-<round>-<role>[-<index>]`) with the slot each was asked to run. Every seat is
    /// listed from the start — queued until its run appears — so the list never grows under
    /// the reader mid-round; an integrator the round turns out not to need stays queued until
    /// the round lands.
    static func expected(_ round: PlannedRound, config: RoundConfig?) -> [(base: String, requested: Slot?)] {
        guard let c = config else { return [] }
        let p = "\(round.stage.rawValue)-\(round.round)-"
        switch round.stage {
        case .draft:
            return c.drafters.enumerated().map { (base: "\(p)drafter-\($0.offset)", requested: $0.element) }
        case .synthesis:
            return [(base: "\(p)synthesizer", requested: c.synthesizer), (base: "\(p)integrator", requested: Slot(c.integrator))]
        case .refine:
            // The reviewer runs its choice with no persona (`RoundExecutor.refine`), so the row
            // doesn't claim one the engine never asked for.
            return [(base: "\(p)reviewer", requested: c.reviewer.map { Slot($0.choice) }),
                    (base: "\(p)integrator", requested: Slot(c.integrator))]
        case .encode:
            return [(base: "\(p)encoder", requested: Slot(c.encoder))]
        case .polish, .freshEyes, .dedup:
            return [(base: "\(p)polisher", requested: c.polisher.map { Slot($0) })]
        }
    }

    static func rows(round: PlannedRound, config: RoundConfig?, seats: SeatFiles, now: Date) -> [LiveSeat] {
        let (activities, records) = (seats.activities, seats.records)
        let runs = Set(activities.keys).union(records.keys)
        var claimed = Set<String>()
        var out: [LiveSeat] = []
        for seat in expected(round, config: config) {
            let mine = runs.filter { belongs($0, to: seat.base) }
            claimed.formUnion(mine)
            // The newest attempt speaks for the seat: a fallback or correction supersedes the
            // run it replaced.
            let run = mine.max { started($0, activities, records) < started($1, activities, records) } ?? seat.base
            let model = SeatRowModel.make(run: run, slot: nil, requested: seat.requested, activity: activities[run],
                                          record: records[run], roundRecord: nil, seatResult: seats.results[run], now: now)
            out.append(LiveSeat(id: seat.base, model: model))
        }
        // A run the config doesn't predict (a config edited mid-round, a role added later) is
        // still shown — dropping it would hide an agent that is really working.
        for run in runs.subtracting(claimed).sorted() {
            out.append(LiveSeat(id: run, model: SeatRowModel.make(run: run, slot: nil, requested: nil,
                                                                  activity: activities[run], record: records[run],
                                                                  roundRecord: nil, seatResult: seats.results[run],
                                                                  now: now)))
        }
        return out
    }

    /// `base` itself, or `base-fallback`/`base-correction` — the dash is what keeps drafter 1
    /// from claiming drafter 10's `…-drafter-10`.
    private static func belongs(_ run: String, to base: String) -> Bool {
        run == base || run.hasPrefix(base + "-")
    }

    private static func started(_ run: String, _ activities: [String: SeatActivity], _ records: [String: RunRecord]) -> Date {
        activities[run]?.startedAt ?? records[run]?.started ?? .distantPast
    }
}

/// Holds each seat's `DwellScheduler` across ticks, and drops those whose seat left the list.
@MainActor
final class DwellBank {
    private var schedulers: [String: DwellScheduler] = [:]

    func settle(_ seats: [LiveSeat]) -> [LiveSeat] {
        let ids = Set(seats.map(\.id))
        schedulers = schedulers.filter { ids.contains($0.key) }
        return seats.map { seat in
            let scheduler = schedulers[seat.id] ?? DwellScheduler()
            schedulers[seat.id] = scheduler
            var seat = seat
            let held = scheduler.offer(headline: seat.model.headline, action: seat.model.action)
            seat.model.headline = held.headline
            seat.model.action = held.action
            return seat
        }
    }
}

// MARK: - Finished rounds

/// The rounds already on the tape, as cards (spec §3.1 "finished rounds as cards") —
/// `ShapingModel.roundCards`' text in the seat rows' visual language. Clicking one shows its
/// plan below; clicking the head again goes back to following the head.
private struct FinishedRounds: View {
    let cards: [RoundCard]
    let tape: Tape
    @Binding var selection: Int?

    var body: some View {
        let selected = selection ?? tape.head?.id
        VStack(alignment: .leading, spacing: 6) {
            Text("Finished rounds")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .padding(.horizontal, 12)
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 8) {
                        ForEach(cards) { card in
                            cardView(card, selected: card.checkpointID == selected)
                                .id(card.checkpointID)
                                .onTapGesture {
                                    selection = card.checkpointID == tape.head?.id ? nil : card.checkpointID
                                }
                        }
                    }
                    .padding(.horizontal, 2)
                }
                // The newest round is the one worth seeing; a long run's first cards are history.
                .onAppear { proxy.scrollTo(cards.last?.checkpointID, anchor: .trailing) }
                .onChange(of: cards.last?.checkpointID) { _, id in proxy.scrollTo(id, anchor: .trailing) }
            }
        }
    }

    private func name(_ card: RoundCard) -> String {
        guard let cp = tape.checkpoints.first(where: { $0.id == card.checkpointID }) else { return card.title }
        return BoardModel.name(stage: cp.stage, round: cp.round)
    }

    private func cardView(_ card: RoundCard, selected: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(name(card)).font(.system(size: 12.5, weight: .semibold))
                Spacer(minLength: 6)
                HStack(spacing: 3) {
                    ForEach(card.slots.indices, id: \.self) { i in slotGlyph(card.slots[i]) }
                }
            }
            Text([card.changes, card.lines].compactMap { $0 }.joined(separator: " · "))
                .font(.system(size: 12))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            if let tally = card.tally {
                Text(tally).font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            if let sections = card.sections {
                Text(sections).font(.system(size: 11.5)).foregroundStyle(.tertiary).lineLimit(1)
            }
            // The note only on the selected card: a row of cards each carrying a paragraph
            // pushed the plan off screen. Every card keeps it as hover text.
            if selected, let note = card.note {
                Text(note).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(6)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        // A horizontal scroll view proposes unlimited width; without a width the note would lay
        // out as one line instead of wrapping.
        .frame(width: 200, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(selected ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.045),
                    in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .strokeBorder(selected ? Color.accentColor.opacity(0.8) : Color.primary.opacity(0.08)))
        .contentShape(Rectangle())
        .help(card.note ?? "")
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("round-card-\(card.checkpointID)")
    }

    private func slotGlyph(_ slot: SlotBadge) -> some View {
        let (symbol, color): (String, Color) = switch slot.status {
        case .ok: ("checkmark.circle.fill", .secondary)
        case .substituted: ("arrow.triangle.swap", .orange)
        case .failed: ("xmark.octagon.fill", .red)
        }
        return Image(systemName: symbol)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(color)
            .help(slot.diagnosis.map { "\(slot.label): \($0)" } ?? slot.label)
            .accessibilityLabel(slot.diagnosis.map { "\(slot.label): \($0)" } ?? slot.label)
    }
}

// MARK: - Clock

/// `.periodic(from:by: 1)` while `ticking`, one frame and then nothing while not — the card's
/// timeline is suspended rather than torn down, so the rows keep their identity (and their
/// chips' expansion) across an occlusion.
struct LiveClockSchedule: TimelineSchedule {
    var ticking: Bool

    func entries(from startDate: Date, mode: TimelineScheduleMode) -> AnyIterator<Date> {
        guard ticking else { return AnyIterator(CollectionOfOne(startDate).makeIterator()) }
        var periodic = PeriodicTimelineSchedule(from: startDate, by: 1).entries(from: startDate, mode: mode).makeIterator()
        return AnyIterator { periodic.next() }
    }
}

/// Whether the hosting window can be seen at all — the same `didChangeOcclusionStateNotification`
/// and `occlusionVisible(_:)` polarity the terminal surfaces use to pause libghostty's renderer
/// (`SurfaceView_AppKit.windowDidChangeOcclusionState`), here gating the card's clock.
private struct WindowVisibilityReader: NSViewRepresentable {
    @Binding var visible: Bool

    func makeNSView(context: Context) -> Probe { Probe() }

    func updateNSView(_ view: Probe, context: Context) {
        let binding = $visible
        view.onChange = { if binding.wrappedValue != $0 { binding.wrappedValue = $0 } }
    }

    final class Probe: NSView {
        var onChange: ((Bool) -> Void)?
        private var observer: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            guard let window else { return }
            observer = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
            ) { [weak self] _ in self?.report() }
            report()
        }

        /// Deferred a turn: this runs inside AppKit's view-hierarchy update, and writing SwiftUI
        /// state from there is a "modifying state during view update" fault.
        private func report() {
            guard let window else { return }
            let visible = occlusionVisible(window.occlusionState)
            DispatchQueue.main.async { [weak self] in self?.onChange?(visible) }
        }

        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }
    }
}
