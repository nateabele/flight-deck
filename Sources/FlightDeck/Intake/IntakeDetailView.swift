import IntakeKit
import SwiftUI

/// The right-hand pane of `ProjectView`'s Intakes split, one selected `Intake` at a time: one
/// calm scrolling document (spec §3, Direction D) — the header, the answered Clarifications, the
/// stage's live card or body, the plan while shaping — over a pinned action bar, with the
/// inspector on the trailing edge. `DetailLayout` decides which parts show and what the action
/// bar says; this view lays them out and wires them to the service.
///
/// **What redraws when.** The running round's seats change about once a second; they publish on
/// this intake's channel of `service.seats`, which only `SeatReader`s observe — the live card,
/// the pinned block and the seat inspector. Everything else here re-evaluates on the service's own, rarer publishes, and
/// the header, the Clarifications and the plan are `Equatable` views on plain values, so even
/// then they redraw only when what they show changed (`RenderProbe` counts it in tests).
struct IntakeDetailView: View {
    /// Observed, not just held: a tape advancing changes `service.tapes` without changing
    /// `intake`, and a plain `let` would let SwiftUI skip this body on exactly that update.
    /// Seat beats are not among its publishes (`SeatFeed`).
    @ObservedObject var service: IntakeService
    let intake: Intake
    /// Opens `ProjectView`'s release-review sheet; the sheet's own state (`reviewIntakeID`)
    /// lives on `ProjectView`, not here, because `ReleaseReviewView` loads its review model
    /// independently in a `.task` keyed on the id ProjectView hands it.
    let onOpenReview: () -> Void
    /// Per project, held by `IntakeService` (`inspectorShown(forProject:)`); `ProjectView`'s
    /// toolbar button (⌥⌘I) toggles it, and Edit in Inspector and the notes open it.
    @Binding var showsInspector: Bool
    /// What the inspector column is actually handed — `showsInspector`, except that a close
    /// pressed while the column is still opening is held until the open is done
    /// (`presentColumn`). Seeded from `showsInspector`: `ProjectView` keys this view on the
    /// intake's id, so a project coming back with its inspector open starts with it open.
    @State private var columnPresented: Bool
    /// When the column was last asked to open, which is what dates the open animation.
    @State private var columnOpenedAt: Date?

    /// Answer drafts for `.needsAnswers`, indexed the same as the current exchange's
    /// questions. Reloaded via `.task(id:)` below whenever the question set changes — the
    /// same `IntakeDetailView` instance lives across a `needsAnswers` → `triaging` →
    /// `needsAnswers` round trip (selection doesn't change), so a plain `@State` seeded
    /// once at init would still hold the previous round's drafts. Mirrored to
    /// `answer-drafts.json` through the service so a relaunch (a release swap) keeps them.
    @State private var answers: [String] = []
    @State private var selectedPreset: Preset = .bead
    /// Indices into `intake.exchanges` whose Clarifications section is open. Collapsed by
    /// default: answered rounds are there to look back at, not to push the live work down.
    @State private var expandedRounds: Set<Int>
    /// Whether the header's request disclosure shows the whole intent. Collapsed by default and
    /// kept per intake the same way `expandedRounds` is: `ProjectView` keys this view on the
    /// intake's id, so another row starts closed and coming back starts closed again.
    @State private var requestExpanded: Bool
    @State private var confirmingDiscard = false
    /// Stop asks first (`PlanningActions.shaping`): set by the bar's key and ⌘. alike.
    @State private var confirmingStop = false
    /// The config `startShaping` hands to `beginShaping` — `nil` until the preset's expansion
    /// seeds it. `beginShaping` rather than `choose` so the edited config is what actually runs.
    @State private var editedConfig: RoundConfig?

    /// The checkpoint the plan section shows; nil follows the plan head. The board, the round
    /// cards and the control bar's Back all move it.
    @State private var selectedCheckpoint: Int?
    /// The finished round whose detail panel is open under the round cards (`FinishedRounds`);
    /// nil for none. Here rather than in the strip so it outlives the live card's 1 Hz redraws,
    /// and per intake like the rest: `ProjectView` keys this view on the intake's id.
    @State private var openRound: Int?
    /// The seat the inspector details (`LiveSeat.id`).
    @State private var selectedSeat: String?
    /// The seat rows' headline holds, shared with the seat inspector so it never says what the
    /// row is still holding back (`DwellBank.peek`). A fresh bank per intake (`bindNotes`).
    @State private var dwell = DwellBank()
    /// The play button being hovered, shared by the control bar and the board so both preview
    /// the same stop.
    @State private var preview: PlayMode?
    /// The plan's notes (spec §7.3), shared by the editor, its selection toolbar and the rail.
    /// `@State`, not `@StateObject`: this body must not re-render on every draft keystroke or
    /// scroll beat — only the views that draw notes observe it.
    @State private var notes = PlanNotesController()
    /// The plan section being read, for the pinned board's breadcrumb (`PlanReadingPosition`).
    @State private var reading = PlanReadingPosition()
    /// Whether the control bar and board have scrolled above the document's top edge and are
    /// drawn pinned under the toolbar instead — see `pinnedBar`.
    @State private var pinned = false
    /// The bar-and-board block's height as last laid out in the card, so the card can hold
    /// exactly that much room while the block is pinned.
    @State private var barHeight: CGFloat = 0
    @State private var boardHeight: CGFloat = 0
    /// The open heatmap's share of `boardHeight` — the pinned copy never draws it, so the height
    /// the pinned block covers leaves it out (`DetailLayout.pinnedBlockHeight`).
    @State private var heatmapHeight: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Derived from files, so kept rather than re-read on every service publish (a running
    /// round publishes about once a second): see `refreshDerived`.
    @State private var summary: [ProgressItem] = []
    @State private var planHead: Int?
    /// The section heatmap under the board (spec §8.3): nil while closed.
    @State private var heatmap: HeatmapFocus?
    /// What the plan was last asked to show by a heatmap cell (`PlanSection.focus`): the diff it
    /// opens scrolls the document to the section's hunk (`PageJump`).
    @State private var planFocus: PlanFocus?
    /// The tape read from disk once the intake is past shaping (`service.tapes` drops it), for
    /// the read-only final plan. Re-read with the other derived values.
    @State private var finalTape: Tape?
    /// The review's drift sentence, once the task graph has been read (`reviewBody`).
    @State private var drift: String?
    /// The document's own scroll view, which the pinned block hands its wheel events to.
    @State private var documentScroll = DocumentScroll()
    /// Opens the CONVERGENCE cell's card without a hover — for offscreen renders.
    private let opensConvergenceCard: Bool

    init(service: IntakeService, intake: Intake, onOpenReview: @escaping () -> Void,
         showsInspector: Binding<Bool> = .constant(false), expandedRounds: Set<Int> = [], requestExpanded: Bool = false,
         selectedSeat: String? = nil,
         heatmap: HeatmapFocus? = nil, opensConvergenceCard: Bool = false) {
        _heatmap = State(initialValue: heatmap)
        self.opensConvergenceCard = opensConvergenceCard
        self.service = service
        self.intake = intake
        self.onOpenReview = onOpenReview
        _showsInspector = showsInspector
        _columnPresented = State(initialValue: showsInspector.wrappedValue)
        _expandedRounds = State(initialValue: expandedRounds)
        _requestExpanded = State(initialValue: requestExpanded)
        _selectedSeat = State(initialValue: selectedSeat)
    }

    private static let scrollSpace = "intake-document"

    private enum Metrics {
        static let margin: CGFloat = 20
        /// `LiveCard`'s own padding: the pinned copy of the bar sits at the card's inset, so it
        /// lands exactly where the card's copy left off.
        static let cardInset: CGFloat = 14
        /// How much the pinned block is taken to cover before its first measurement.
        static let pinnedEstimate: CGFloat = 300
    }

    var body: some View {
        let _ = RenderProbe.hit("detail")
        let sections = DetailLayout.sections(for: intake.state, hasClarifications: !answeredRounds.isEmpty)
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        DetailHeader(state: intake.state, intent: intake.intent, summary: summary,
                                     expanded: requestExpanded, setExpanded: { requestExpanded = $0 })
                            .equatable()
                        if sections.contains(.clarifications) {
                            ClarificationsSection(exchanges: intake.exchanges, expanded: expandedRounds,
                                                  setExpanded: { index, open in
                                                      if open { expandedRounds.insert(index) } else { expandedRounds.remove(index) }
                                                  })
                                .equatable()
                        }
                        if sections.contains(.liveCard) { liveCard.id(Self.cardAnchor) }
                        if sections.contains(.stageBody) { stageBody }
                        if sections.contains(.plan) { planSection }
                    }
                    .padding(.horizontal, Metrics.margin)
                    .padding(.vertical, 18)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .background(DocumentScrollAnchor(scroll: documentScroll))
                    // The plan is part of this document, so its jumps (a heatmap cell's
                    // section) scroll this scroll view, which only this reader can reach.
                    .environment(\.pageJump, PageJump { [reduceMotion, documentScroll] id, below in
                        let anchor = PageJump.anchor(below: below, height: documentScroll.view?.contentView.bounds.height ?? 0)
                        withAnimation(reduceMotion ? nil : .default) { proxy.scrollTo(id, anchor: anchor) }
                    })
                }
                .coordinateSpace(name: Self.scrollSpace)
                .onPreferenceChange(BarGeometryKey.self, perform: barMoved)
                // An overlay, not `.safeAreaInset`: an inset changes the scroll view's content
                // insets, which moves the very geometry the pin is decided from — pinning would
                // unpin it, and the block would flicker at the threshold.
                .overlay(alignment: .top) { pinnedBar }
                // The heatmap lives in the card's board, never the pinned copy's: opened
                // while the block is pinned (the cell on the pinned bar, the Run menu), it
                // would open out of sight, so the document brings the card to it.
                .onChange(of: heatmap == nil) { _, closed in
                    guard !closed, pinned else { return }
                    withAnimation(reduceMotion ? nil : .default) { proxy.scrollTo(Self.cardAnchor, anchor: .top) }
                }
            }
            // Pinned outside the ScrollView so the way forward (and out) is always in reach,
            // however long the questions or the plan run.
            if sections.contains(.actionBar) {
                Divider()
                actionBar
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityIdentifier("intake-detail")
        .inspector(isPresented: inspectorPresented) {
            inspector
                .inspectorColumnWidth(min: 300, ideal: 440, max: 640)
        }
        // Scene-wide, not focus-scoped: nothing in the document takes focus on a click (the
        // transport keys are plain buttons), so a focused value left ⌘' and ⌘. dark the whole
        // time a run was on screen. No terminal shares the window's detail column while an
        // intake is shown, so no surface competes for them. One modifier with an optional
        // value, not one per branch: switching branches gave the pane a new identity each time
        // the run started or stopped, resetting every piece of state below.
        .focusedSceneValue(\.planningActions, planningActions)
        // Esc closes the heatmap from anywhere in the pane, not only while it holds focus: a
        // click into the plan moves focus to the editor, and the map stayed open under it.
        // The round panel likewise, once no heatmap is open over it.
        .onExitCommand(perform: heatmap != nil ? { heatmap = nil }
                       : openRound != nil ? { withAnimation(reduceMotion ? nil : .smooth(duration: 0.3)) { openRound = nil } }
                       : nil)
        // Stop is destructive, so neither its key nor ⌘. acts without this (spec §2). Cancel is
        // the default: a Return on a reflex ⌘. must not throw the round away.
        .confirmationDialog("Stop the run?", isPresented: $confirmingStop, titleVisibility: .visible) {
            Button("Stop", role: .destructive) { [service, id = intake.id] in service.send(id, .stop) }
            Button("Cancel", role: .cancel) {}.keyboardShortcut(.defaultAction)
        } message: {
            Text(PlanningActions.stopMessage(tape: tape ?? .empty))
        }
        .onChange(of: derivedKey, initial: true) { refreshDerived() }
        .onChange(of: intake.id, initial: true) { bindNotes() }
        .onChange(of: showsInspector, initial: true) { _, shown in presentColumn(shown) }
        .onChange(of: service.notes(intake.id), initial: true) { _, onTape in notes.tapeNotes = onTape }
        // Choosing a seat is asking the inspector about the run, not the plan.
        .onChange(of: selectedSeat) { _, seat in if seat != nil { notes.planFocused = false } }
        // An open round panel follows the plan's round when the board, ⌘[ or a banner moves
        // it: a panel describing one round over a plan showing another reads as a stale pane.
        .onChange(of: selectedCheckpoint) { _, checkpoint in
            guard openRound != nil, let round = checkpoint ?? tape?.head?.id, round != openRound else { return }
            withAnimation(reduceMotion ? nil : .smooth(duration: 0.3)) { openRound = round }
        }
    }

    /// How long the column's open animation is taken to run. It took about a second with the
    /// plan relaying out beside it (`ProjectViewInspectorLiveTests`, offscreen, a cold window);
    /// the rest is margin. A cold open slower than this can still lose a close.
    static let openSettle: TimeInterval = 1.2

    /// The column as `.inspector` is handed it. A close pressed while the column is still
    /// opening is lost two ways, and this guards the one `presentColumn` can't: AppKit finishes
    /// the open and writes `true` back over the human's close — ⌥⌘I or the toolbar hid the
    /// inspector and it came straight back. Nothing but this pane's own openers has a reason
    /// to open the column, so an open it reports while closed is that lost close: accept what
    /// it says, then close again, now that nothing is animating. A drag that collapses the
    /// column is a real close and lands as is.
    private var inspectorPresented: Binding<Bool> {
        Binding(get: { columnPresented }, set: { shown in
            columnPresented = shown
            guard shown && !showsInspector else {
                showsInspector = shown
                return
            }
            // Through `presentColumn`, not straight to `false`: inside the open window this
            // write-back lands while the close is still held, and closing at once started a
            // collapse mid-open whose own late write-back of `false` then undid a reopen.
            DispatchQueue.main.async { presentColumn(showsInspector) }
        })
    }

    /// Follows `showsInspector` into the column, holding a close that arrives within
    /// `openSettle` of the open until that window ends. The other way the close is lost:
    /// `.inspector(isPresented:)` drops a `false` that lands mid-animation without a word —
    /// AppKit never writes back, so the write-back guard above never runs, and the toolbar
    /// said "Show Inspector" over a column that stayed open for good (6 s later, still open;
    /// a log in the binding's setter never fired). Re-sending `false` is no cure, since SwiftUI
    /// pushes a binding only on a change. The held close re-reads `showsInspector` when it
    /// fires, so a reopen in between cancels it rather than closing the column under it.
    private func presentColumn(_ shown: Bool) {
        if shown {
            if !columnPresented { columnOpenedAt = Date() }
            columnPresented = true
            return
        }
        guard columnPresented else { return }
        let remaining = columnOpenedAt.map { Self.openSettle + $0.timeIntervalSinceNow } ?? 0
        guard remaining > 0 else {
            columnPresented = false
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + remaining) { [$showsInspector, $columnPresented] in
            if !$showsInspector.wrappedValue { $columnPresented.wrappedValue = false }
        }
    }

    // MARK: - Header

    /// Everything the header summary and Back's "plan head" depend on — what re-derives them.
    private var derivedKey: DerivedKey {
        DerivedKey(state: intake.state, exchanges: intake.exchanges.count,
                   checkpoints: tape?.checkpoints.map(\.id) ?? [],
                   triageFinished: service.triageActivity(intake.id)?.finished ?? false)
    }

    private func refreshDerived() {
        finalTape = DetailLayout.planIsFinal(for: intake.state) ? service.storedTape(intake.id) : nil
        let tape = planTape ?? .empty
        let load: (Int, String) -> Data? = { [service, id = intake.id] in service.checkpointFile(id, checkpoint: $0, $1) }
        summary = ProgressSummary.line(intake: intake, tape: tape, triage: service.triageActivity(intake.id), loadFile: load)
            .map { ProgressItem(label: $0.label, detail: $0.detail) }
        planHead = PlanSection.planHead(tape: tape, loadFile: load)
    }

    // MARK: - Live card

    private var tape: Tape? { service.tapes[intake.id] }
    /// The tape the plan section reads: the live one while shaping, the stored one after.
    private var planTape: Tape? { DetailLayout.planIsFinal(for: intake.state) ? finalTape : tape }

    @ViewBuilder
    private var liveCard: some View {
        switch intake.state {
        case .triaging:
            LiveCard.triage(intake: intake, activity: service.triageActivity(intake.id), pending: service.pending[intake.id])
        case .shaping:
            let tape = tape ?? .empty
            SeatReader(feed: service.seats, id: intake.id) { seats in
                let _ = RenderProbe.hit("liveCard")
                LiveCard.shaping(intake: intake, tape: tape, activities: seats.activities, records: seats.records,
                                 results: seats.results, pending: service.pending[intake.id],
                                 editConflict: service.editConflictNotice(intake.id, tape: tape, head: planHead),
                                 selectedRound: $selectedCheckpoint,
                                 openRound: $openRound,
                                 selectedSeat: $selectedSeat,
                                 dwell: dwell,
                                 controlBar: { now in
                                     AnyView(inCard(.bar, height: barHeight) { controlBar(tape, now: now, seats: seats) })
                                 },
                                 board: { now in AnyView(inCard(.board, height: boardHeight) { board(tape, now: now, pinned: false) }) })
            }
        default:
            EmptyView()
        }
    }

    /// The card's copy of the bar or board, or — while the block is pinned — a clear stand-in
    /// of the same height, so exactly one copy is ever live: two would each play the split-flap
    /// for a new value, and the one scrolled out of sight could spend the flap the visible one
    /// should have shown. Both report where they are, which is what decides the pin.
    private func inCard(_ part: BarGeometryKey.Part, height: CGFloat, @ViewBuilder content: () -> some View) -> some View {
        Group {
            if pinned { Color.clear.frame(height: height) } else { content() }
        }
        .background(GeometryReader { geo in
            let frame = geo.frame(in: .named(Self.scrollSpace))
            Color.clear.preference(key: BarGeometryKey.self,
                                   value: part == .bar ? BarFrames(bar: frame) : BarFrames(board: frame))
        })
    }

    private func barMoved(_ geometry: BarFrames) {
        let pins = DetailLayout.pinsBar(barTop: geometry.bar?.minY)
        if pins != pinned { pinned = pins }
        // Only the live copies measure their content; a stand-in reports back what it was given.
        if !pinned {
            if let bar = geometry.bar, abs(bar.height - barHeight) > 0.5 { barHeight = bar.height }
            if let board = geometry.board, abs(board.height - boardHeight) > 0.5 { boardHeight = board.height }
            let map = geometry.heatmap?.height ?? 0
            if abs(map - heatmapHeight) > 0.5 { heatmapHeight = map }
        }
    }

    /// The bar and board, pinned under the toolbar once the card's copy scrolls out (spec §3).
    /// Its own `LiveClock` — the card's clock is scrolled away with the card — on the same whole
    /// seconds as the card's (`LiveClockSchedule`), so it never reads a second apart from the
    /// rows still visible below it.
    @ViewBuilder
    private var pinnedBar: some View {
        if pinned, intake.state == .shaping, let tape {
            SeatReader(feed: service.seats, id: intake.id) { seats in
                LiveClock(mode: .shaping(tape: tape, pending: service.pending[intake.id])) { now in
                    VStack(spacing: DetailLayout.pinnedGap) {
                        controlBar(tape, now: now, seats: seats)
                        board(tape, now: now, pinned: true)
                    }
                }
            }
            .padding(.horizontal, Metrics.margin + Metrics.cardInset)
            .padding(.top, DetailLayout.pinnedInset)
            .padding(.bottom, 10)
            .background(Color(nsColor: .windowBackgroundColor).shadow(.drop(color: .black.opacity(0.35), radius: 6, y: 2)))
            // Clear of the document's scroller, which the block would otherwise cover: the
            // scroller is how the human sees where in the document they are.
            .padding(.trailing, Self.scrollerWidth)
            // The block is not inside the document's scroll view, so a wheel over it reached
            // nothing that scrolls: hand it to the document instead.
            .background(WheelToDocument(scroll: documentScroll))
            .accessibilityIdentifier("intake-pinned-bar")
        }
    }

    @ViewBuilder
    private func controlBar(_ tape: Tape, now: Date, seats: SeatFiles) -> some View {
        if let config = intake.roundConfig {
            let board = boardModel(tape, config: config, now: now)
            let cell = convergenceCell
            let coverage = coverageCell(tape, config: config)
            let lcd = LCDModel(tape: tape, config: config, board: board,
                               seats: seatModels(tape, config: config, now: now, seats: seats),
                               convergence: cell, coverage: coverage, preview: preview, now: now)
            ControlBar(lcd: lcd, convergence: cell, coverage: coverage, actions: planningActions ?? PlanningActions(enabled: [], perform: { _ in }),
                       status: tape.status, defaultPlay: config.defaultPlay,
                       halting: service.halts[intake.id]?.label(for: tape), policy: service.flapPolicy(for: intake.id),
                       preview: $preview,
                       setDefaultPlay: { [service, id = intake.id] in service.setDefaultPlay(id, $0) },
                       onBack: backAction(tape), nextRound: notes.summary.tooltip, heatmapOpen: heatmap != nil,
                       onConvergence: { heatmap = heatmap == nil ? HeatmapFocus() : nil },
                       opensConvergenceCard: opensConvergenceCard)
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }

    /// `pinned`: the pinned copy has no heatmap. Carried there, a cell's jump to the plan pinned
    /// the block and the opaque map covered the very section it had jumped to; the card's copy
    /// keeps it, and reports its height so the pinned room can leave it out.
    @ViewBuilder
    private func board(_ tape: Tape, now: Date, pinned: Bool) -> some View {
        if let config = intake.roundConfig {
            let model = boardModel(tape, config: config, now: now)
            DeparturesBoard(model: model, policy: service.flapPolicy(for: intake.id),
                            preview: $preview,
                            onSelect: { select($0) },
                            onExtend: { [service, id = intake.id] in service.send(id, .extend($0, by: 1)) },
                            onTrim: { [service, id = intake.id] in service.send(id, .trim($0, by: 1)) },
                            disclosure: pinned ? nil : heatmapView(tape, board: model).map { map in
                                AnyView(map.background(GeometryReader { geo in
                                    Color.clear.preference(key: BarGeometryKey.self,
                                                           value: BarFrames(heatmap: geo.frame(in: .named(Self.scrollSpace))))
                                }))
                            },
                            footer: pinned ? AnyView(PlanReadingCrumb(position: reading)) : nil)
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }

    // MARK: - Convergence

    private var cycles: [ConvergenceCycle] { service.convergence[intake.id] ?? [] }

    /// The CONVERGENCE cell: the current cycle, with the rounds past its planned length marked.
    private var convergenceCell: ConvergenceCellModel? { cell(cycles) }

    /// The cell for the last of `cycles`, told how many rounds its stage was planned to run.
    private func cell(_ cycles: [ConvergenceCycle]) -> ConvergenceCellModel? {
        let planned = cycles.last.flatMap { cycle in
            intake.roundConfig.map { cycle.stage == .refine ? $0.refinementCap : $0.polishCap }
        }
        return ConvergenceCellModel(cycles: cycles, plannedRounds: planned)
    }

    /// The COVERAGE cell, from the folded readings beside the convergence series.
    private func coverageCell(_ tape: Tape, config: RoundConfig) -> CoverageCellModel? {
        CoverageCellModel(intake: intake, tape: tape, config: config, readings: service.coverage[intake.id] ?? [], cycles: cycles)
    }

    /// The cycle the heatmap and the churn lane describe (`HeatmapModel.sectionCycle`).
    private var sectionCycle: ConvergenceCycle? { HeatmapModel.sectionCycle(cycles) }

    private func heatmapView(_ tape: Tape, board: BoardModel) -> AnyView? {
        guard let heatmap, let cycle = sectionCycle else { return nil }
        let map = HeatmapModel(cycle: cycle)
        return AnyView(ConvergenceHeatmap(
            model: map, cell: cell([cycle]),
            columns: { DeparturesBoard.slotColumns(board, slotIDs: map.slotIDs, width: $0) },
            focusSection: heatmap.section, selectedCheckpoint: selectedCheckpoint ?? tape.head?.id,
            onSelect: { checkpoint, section in
                select(checkpoint)
                planFocus = PlanFocus(checkpoint: checkpoint, section: section, seq: (planFocus?.seq ?? 0) + 1)
            },
            onAnnotate: { [notes] section in notes.annotate(section: section) },
            onClose: { self.heatmap = nil }))
    }

    private func churnLane() -> ChurnLaneInput? {
        guard let cycle = sectionCycle else { return nil }
        let load: (Int, String) -> Data? = { [service, id = intake.id] in service.checkpointFile(id, checkpoint: $0, $1) }
        return ChurnLaneInput(cycle: cycle,
                              versions: { ChurnLaneModel.versions(cycle: cycle, section: $0, loadFile: load) },
                              onOpen: { heatmap = HeatmapFocus(section: $0) })
    }

    private func boardModel(_ tape: Tape, config: RoundConfig, now: Date) -> BoardModel {
        BoardModel(intake: intake, tape: tape, config: config, now: now, selected: selectedCheckpoint, preview: preview)
    }

    /// The round in progress's seats, as the card's rows draw them — AGENTS DONE and BILLED count
    /// the same seats the rows below show. A start not yet heard from shows none, as the card does.
    private func seatModels(_ tape: Tape, config: RoundConfig, now: Date, seats: SeatFiles) -> [SeatRowModel] {
        guard let round = tape.roundInProgress, service.pending[intake.id] == nil else { return [] }
        return LiveSeats.rows(round: round, config: config, seats: seats, now: now).map(\.model)
    }

    /// Back is navigation in the plan viewer (the `ControlBar.onBack` contract): one checkpoint
    /// before the one shown, which is the plan head while following. Nil dims the key.
    private func backAction(_ tape: Tape) -> (() -> Void)? {
        guard let previous = DetailLayout.previousCheckpoint(before: selectedCheckpoint ?? planHead, in: tape) else { return nil }
        return { select(previous) }
    }

    /// Choosing the plan head goes back to following it, so the next round's plan arrives
    /// without a second click — the same rule the round cards follow.
    private func select(_ checkpoint: Int) {
        selectedCheckpoint = checkpoint == planHead ? nil : checkpoint
    }

    /// What the Run menu and the bar's keys press (`PlanningActions`); nil outside shaping, which
    /// leaves every Run item disabled.
    private var planningActions: PlanningActions? {
        guard intake.state == .shaping, let tape else { return nil }
        var actions = PlanningActions.shaping(intake.id, service: service, model: ShapingModel(intake: intake, tape: tape),
                                              annotate: { [notes] in notes.annotate() },
                                              confirmStop: { [$confirmingStop] in $confirmingStop.wrappedValue = true })
        if sectionCycle != nil {
            actions.heatmap = PlanningActions.HeatmapToggle(open: heatmap != nil) { [$heatmap] in
                $heatmap.wrappedValue = $heatmap.wrappedValue == nil ? HeatmapFocus() : nil
            }
        }
        return actions
    }

    /// A different intake starts with a clean slate of notes, sending to itself.
    private func bindNotes() {
        dwell = DwellBank()
        notes.reset()
        notes.send = { [service, id = intake.id] in service.send(id, $0) }
        notes.showRail = { [$showsInspector] in $showsInspector.wrappedValue = true }
    }

    // MARK: - Plan

    /// The plan as part of the document: as tall as its text, scrolled by the document's one
    /// scroller, under the pinned bar and board like everything else. The block's height is
    /// what the editor keeps clear above its caret and a heatmap jump lands below
    /// (`pageObscuredTop`). The final plan (review on) has no pinned block over it.
    private var planSection: some View {
        let final = DetailLayout.planIsFinal(for: intake.state)
        let pinnedHeight = final ? 0
            : DetailLayout.pinnedBlockHeight(bar: barHeight, board: boardHeight, heatmap: heatmapHeight) ?? Metrics.pinnedEstimate
        return DocumentPlan(service: service, intakeID: intake.id, projectPath: intake.projectPath, title: DetailLayout.planTitle(for: intake.state),
                            tape: planTape ?? .empty, final: final,
                            selection: final ? nil : selectedCheckpoint, select: final ? .constant(nil) : $selectedCheckpoint,
                            focus: final ? nil : planFocus, churn: final ? nil : churnLane(),
                            noteShown: service.editNoteShown.contains(intake.id), notes: final ? nil : notes,
                            onOpenNotes: {
                                notes.planFocused = true
                                showsInspector = true
                            })
            .equatable()
            .environment(\.pageObscuredTop, pinnedHeight)
            .environment(\.planReading, final ? nil : reading)
    }

    // MARK: - Stage bodies

    @ViewBuilder
    private var stageBody: some View {
        switch intake.state {
        case .needsAnswers: needsAnswersBody
        case .awaitingChoice: awaitingChoiceBody
        case .parked: parkedBody
        case .review: reviewBody
        case .releasing: releasingBody
        case .released, .partiallyReleased: releasedBody
        case .failed, .interrupted: failedBody
        // Triage and shaping draw a live card instead; a discarded intake is never listed.
        case .triaging, .shaping, .discarded: EmptyView()
        }
    }

    private var openQuestions: [String] {
        guard let open = intake.exchanges.last, open.answers == nil else { return [] }
        return open.questions
    }

    /// The open round as a grouped form: numbered, fully wrapped questions, each over a
    /// multi-line answer field. Sent rounds leave this form and reappear under Clarifications.
    private var needsAnswersBody: some View {
        let questions = openQuestions
        return VStack(alignment: .leading, spacing: 6) {
            Text(questions.count == 1 ? "Question" : "Questions").font(.headline)
            GroupedRows(count: questions.count) { i in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(i + 1).")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(questions[i])
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                        TextField("Answer \(i + 1)", text: answerBinding(i), prompt: Text("Your answer"), axis: .vertical)
                            .labelsHidden()
                            .lineLimit(2...6)
                            .textFieldStyle(.roundedBorder)
                    }
                }
            }
            Text("Triage continues once every question has an answer. Press ⌘↩ to send.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        // Keyed on the questions' CONTENTS (and the intake): a follow-up round with the same
        // number of questions used to keep the previous round's answers typed into the new
        // questions' fields, ready to send against questions they never answered.
        .task(id: [intake.id.uuidString] + questions) {
            answers = service.answerDrafts(intake.id, questions: questions)
                ?? Array(repeating: "", count: questions.count)
        }
        // Debounced write-through: every keystroke restarts this task, so the file is written
        // once typing pauses. `saveAnswerDrafts` refuses a round already sent, so a write
        // racing Send can't resurrect it.
        .task(id: answers) { [answers, id = intake.id] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            service.saveAnswerDrafts(id, questions: questions, answers: answers)
        }
    }

    private func answerBinding(_ index: Int) -> Binding<String> {
        Binding(
            get: { index < answers.count ? answers[index] : "" },
            set: { newValue in
                guard index < answers.count else { return }
                answers[index] = newValue
            }
        )
    }

    /// At least one answer, and none of them blank once whitespace/newlines are trimmed —
    /// otherwise "Send answers" would ship empty strings straight to `IntakeService.answer`,
    /// which has no guard of its own against that (it only checks `state == .needsAnswers`
    /// and a non-empty exchange).
    static func canSendAnswers(_ answers: [String]) -> Bool {
        !answers.isEmpty && !answers.contains { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// Spec §9: the recommendation, the fidelity as a segmented choice, and the rounds it will
    /// run in one line — the grid itself lives in the inspector, where it can be as wide as it
    /// needs without pushing Start Planning off screen.
    private var awaitingChoiceBody: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let recommended = intake.recommended {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Recommended: \(UIText.presetName(recommended))").font(.callout.weight(.semibold))
                    if let reason = intake.recommendationReason {
                        Text(reason)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Picker("Fidelity", selection: $selectedPreset) {
                ForEach(Self.allPresets, id: \.self) { preset in
                    Text(UIText.presetName(preset)).tag(preset)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .accessibilityIdentifier("intake-fidelity-picker")
            if selectedPreset == .bead {
                Text("Writes one task straight from triage, with no planning rounds.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else if let config = editedConfig {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(RoundConfigEditor.summary(preset: selectedPreset, config: config))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Edit in Inspector") { showsInspector = true }
                        .buttonStyle(.link)
                        // The only way to change a stage's round count before the run: say so,
                        // since the summary line alone reads as a fixed description.
                        .help("Change the agents and how many rounds each stage runs — a cap of 0 removes the stage")
                        .accessibilityIdentifier("intake-edit-in-inspector")
                }
            }
        }
        .task(id: intake.id) { selectedPreset = intake.recommended ?? .bead; seedConfig() }
        .onChange(of: selectedPreset) { seedConfig() }
    }

    /// Re-seeded whenever the preset changes, so an edit to Full plan's config never leaks
    /// into Sketch's.
    private func seedConfig() {
        editedConfig = PresetExpansion.config(for: selectedPreset, available: service.availableModels())
    }

    private func startShaping() {
        guard let config = editedConfig ?? PresetExpansion.config(for: selectedPreset, available: service.availableModels())
        else { return }
        service.beginShaping(intake.id, preset: selectedPreset, config: config)
    }

    /// Chosen before planning rounds existed; the same choice as `.awaitingChoice` resumes it.
    private var parkedBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Parked before planning rounds existed. Choose a fidelity to continue.").foregroundStyle(.secondary)
            awaitingChoiceBody
        }
    }

    /// What the review will write, counted, and whether the task graph moved since triage —
    /// so the pane says what Review Tasks… opens onto before it is opened. The drift needs the
    /// graph read (`IntakeService.reviewModel`), so it follows a beat after the counts, once
    /// per visit and again when a confirm or drop in the sheet changes the answer.
    private var reviewBody: some View {
        VStack(alignment: .leading, spacing: 6) {
            // A refused release comes back here with its reason — without this line the only
            // trace of the refusal was the sheet having closed. Red: it is a failure, and amber
            // is for attention (spec §2).
            if let failure = intake.failure {
                Text(failure).foregroundStyle(.red).padding(.bottom, 6)
            }
            Text("Change set").font(.headline)
            Text(DetailLayout.reviewCounts(intake.changeSet?.ops ?? []))
                .accessibilityIdentifier("intake-review-counts")
            Text(drift ?? "Checking the task graph for changes since triage…")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("intake-review-drift")
        }
        .task(id: ReviewKey(id: intake.id, confirmed: intake.confirmedDrift, dropped: intake.droppedOps)) {
            drift = nil
            guard let review = await service.reviewModel(intake.id) else {
                drift = "The review checks the task graph for changes since triage."
                return
            }
            drift = DetailLayout.driftLine(review.drift, confirmed: review.intake.confirmedDrift, dropped: review.intake.droppedOps)
        }
    }

    private var releasingBody: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Releasing…")
        }
        .foregroundStyle(.secondary)
    }

    private var releasedBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let record = intake.release {
                Text("\(record.appliedSteps) step\(record.appliedSteps == 1 ? "" : "s") applied")
                if let error = record.error {
                    Text(error).foregroundStyle(.red)
                }
                if !record.warnings.isEmpty {
                    DisclosureGroup("Delivery warnings (\(record.warnings.count))") {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(record.warnings, id: \.self) { warning in
                                Text(warning).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
    }

    private var failedBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let failure = intake.failure {
                Text(failure).foregroundStyle(.red)
            }
            if let raw = intake.rawFailureOutput {
                DisclosureGroup("Raw output") {
                    ScrollView {
                        Text(raw)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 200)
                }
            }
        }
    }

    // MARK: - Answered rounds

    /// "Round 1 · 3 questions" — numbered by position in `exchanges`, so a round keeps its
    /// number whichever state the intake is reviewed from.
    static func roundLabel(index: Int, exchange: TriageExchange) -> String {
        let n = exchange.questions.count
        return "Round \(index + 1) · \(n) question\(n == 1 ? "" : "s")"
    }

    // MARK: - Inspector

    /// The rail fills the column edge to edge and scrolls with the editor, not on its own, so it
    /// sits outside the ScrollView every other inspector shares.
    private var inspector: some View {
        PlanFocusReader(notes: notes) { planFocused in
            let content = DetailLayout.inspector(for: intake.state, preset: selectedPreset, planFocused: planFocused)
            if content == .notesRail {
                notesRailSlot
            } else {
                ScrollView {
                    Group {
                        switch content {
                        case .roundsEditor: roundsEditor
                        case .seat: seatInspector
                        case .notesRail: EmptyView()
                        case .nothing:
                            InspectorPlaceholder(title: "Nothing to Inspect",
                                                 message: "The rounds for a plan, and the agents of a running round, show here.")
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
        }
        .accessibilityIdentifier("intake-inspector")
    }

    @ViewBuilder
    private var roundsEditor: some View {
        if let config = editedConfig {
            RoundConfigEditor(preset: selectedPreset, config: Binding(get: { config }, set: { editedConfig = $0 }),
                              available: service.availableModels())
        }
    }

    /// Resolved on each tick rather than held: a seat's row model is re-derived from the service
    /// each second, and the inspector follows it (a fallback starting, a result landing). On its
    /// own `LiveClock`, on the card's whole seconds, and through the card's own reads — the
    /// pending substitution and the row's dwell hold. With `Date()` and the raw files it froze
    /// between seat writes, and could say "Running" beside a row that said the seat had stalled.
    @ViewBuilder
    private var seatInspector: some View {
        if let tape, let round = tape.roundInProgress, let selectedSeat {
            let pending = service.pending[intake.id]
            SeatReader(feed: service.seats, id: intake.id) { seats in
                LiveClock(mode: .shaping(tape: tape, pending: pending)) { now in
                    let files = LiveSeats.files(seats, pending: pending)
                    if let seat = LiveSeats.rows(round: round, config: intake.roundConfig, seats: files, now: now)
                        .first(where: { $0.id == selectedSeat }).map(dwell.peek) {
                        SeatInspector(model: seat.model, activity: files.activities[seat.model.id],
                                      runDirectory: service.runDirectory(intake.id, run: seat.model.id))
                    } else {
                        InspectorPlaceholder(title: "No Agent Selected", message: "Click an agent in the round to see its details.")
                    }
                }
            }
        } else if tape?.roundInProgress == nil {
            InspectorPlaceholder(title: "No Round Running", message: "Agents show here while a round is at work.")
        } else {
            InspectorPlaceholder(title: "No Agent Selected", message: "Click an agent in the round to see its details.")
        }
    }

    /// The notes rail, while the plan is focused (`DetailLayout.InspectorContent.notesRail`).
    private var notesRailSlot: some View {
        NotesRail(controller: notes, roundName: { [tape] id in
            tape?.checkpoints.first { $0.id == id }.map(PlanSection.checkpointName)
        })
    }

    // MARK: - Action bar

    /// macOS HIG button placement: the destructive Discard alone on the leading edge, where it
    /// can't be hit in place of the primary; the primary on the trailing edge as the default
    /// button. Every state has a way off the list except `.releasing`, which
    /// `IntakeService.discard` refuses (tasks half-written, no record yet). Before that an
    /// intake stuck at a question, a choice or the review had no exit, and a
    /// `.partiallyReleased` one — which counts as needing attention — kept its project's
    /// orange badge lit forever.
    private var actionBar: some View {
        HStack(spacing: 8) {
            if DetailLayout.closeAction(for: intake.state) != nil {
                Button("Discard", role: .destructive) { confirmingDiscard = true }
                    .accessibilityIdentifier("intake-discard")
            }
            Spacer()
            if let title = DetailLayout.primaryAction(for: intake.state, preset: selectedPreset) {
                primaryButton(title)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .confirmationDialog("Discard this intake?", isPresented: $confirmingDiscard, titleVisibility: .visible) {
            Button("Discard", role: .destructive) { service.discard(intake.id) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It leaves the list. Nothing already written to tasks is undone.")
        }
    }

    /// The key per `DetailLayout.primaryKey`: ⌘↩ for Send Answers, whose multi-line fields own
    /// Return; none for a partial release's Dismiss, so a stray Return can't hide it.
    @ViewBuilder
    private func primaryButton(_ title: String) -> some View {
        let button = Button(title) { performPrimary() }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("intake-primary-action")
        switch DetailLayout.primaryKey(for: intake.state) {
        case .commandReturn:
            button
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!Self.canSendAnswers(answers))
        case .defaultAction: button.keyboardShortcut(.defaultAction)
        case .none: button
        }
    }

    private func performPrimary() {
        switch intake.state {
        case .needsAnswers:
            guard Self.canSendAnswers(answers) else { return }
            service.answer(intake.id, answers: answers)
        case .awaitingChoice, .parked:
            if selectedPreset == .bead { service.choose(intake.id, preset: .bead) } else { startShaping() }
        case .review: onOpenReview()
        // Not destructive: `discard` only hides a released intake; its record stays on disk.
        case .released, .partiallyReleased: service.discard(intake.id)
        case .failed, .interrupted: service.retry(intake.id)
        case .triaging, .shaping, .releasing, .discarded: break
        }
    }

    private var answeredRounds: [Int] { intake.exchanges.indices.filter { intake.exchanges[$0].answers != nil } }

    private static let allPresets: [Preset] = [.bead, .sketch, .featurePlan, .fullPlan]

    private static let cardAnchor = "intake-live-card"

    /// The document scroller's width in the current scroller style — zero-width overlay
    /// scrollers still draw over the content's trailing edge while scrolling.
    private static var scrollerWidth: CGFloat {
        NSScroller.scrollerWidth(for: .regular, scrollerStyle: NSScroller.preferredScrollerStyle)
    }
}

// MARK: - Support

/// One finished phase in the header's summary line.
private struct ProgressItem: Identifiable, Equatable {
    var id: String { label }
    let label: String
    let detail: String
}

private struct DerivedKey: Equatable {
    let state: IntakeState
    let exchanges: Int
    let checkpoints: [Int]
    let triageFinished: Bool
}

/// Where the card's copies of the control bar and the board sit in the document's viewport.
private struct BarFrames: Equatable {
    var bar: CGRect?
    var board: CGRect?
    /// The card's open heatmap, inside `board`.
    var heatmap: CGRect?
}

private struct BarGeometryKey: PreferenceKey {
    enum Part { case bar, board }
    static let defaultValue = BarFrames()

    static func reduce(value: inout BarFrames, nextValue: () -> BarFrames) {
        let next = nextValue()
        value.bar = next.bar ?? value.bar
        value.board = next.board ?? value.board
        value.heatmap = next.heatmap ?? value.heatmap
    }
}

/// Counts body evaluations by name, in debug builds only — how a test proves a seat beat
/// redraws the live card and nothing else in the pane. A no-op in release.
@MainActor
enum RenderProbe {
    private(set) static var counts: [String: Int] = [:]

    static func hit(_ name: String) {
        #if DEBUG
        counts[name, default: 0] += 1
        #endif
    }

    static func reset() { counts = [:] }
}

/// Re-reads only intake `id`'s seat files (`SeatFeed`), so a seat beat redraws what is drawn
/// from them and not the pane around it.
private struct SeatReader<Content: View>: View {
    let feed: SeatFeed
    let id: UUID
    /// This intake's channel only: another intake's beats never redraw this reader.
    @ObservedObject private var channel: SeatChannel
    @ViewBuilder let content: (SeatFiles) -> Content

    init(feed: SeatFeed, id: UUID, @ViewBuilder content: @escaping (SeatFiles) -> Content) {
        self.feed = feed
        self.id = id
        self.channel = feed.channel(id)
        self.content = content
    }

    var body: some View { content(feed.files(id)) }
}

/// The eyebrow ("INTAKE · SHAPING"), the request as its own disclosure, and the phases done so
/// far. Plain values, so it redraws only when one of them changes; `setExpanded` is not compared.
///
/// The request IS the disclosure: collapsed, the chevron sits beside its title (`IntakeTitle`, the
/// first sentence or clause); open, the same line runs on into the rest of the request. An intent
/// is often a paragraph, and set whole as a bold title it towered over the page and pushed the
/// live work below the fold. A separate "Request · Full text" section under the title (the first
/// cut of this) read as a second heading that only repeated the first.
private struct DetailHeader: View, Equatable {
    let state: IntakeState
    let intent: String
    let summary: [ProgressItem]
    let expanded: Bool
    let setExpanded: (Bool) -> Void

    static func == (a: Self, b: Self) -> Bool {
        a.state == b.state && a.intent == b.intent && a.summary == b.summary && a.expanded == b.expanded
    }

    var body: some View {
        let _ = RenderProbe.hit("header")
        VStack(alignment: .leading, spacing: 4) {
            (Text("Intake · ") + Text(IntakeStatePill.stateName(state))
                .foregroundColor(state.needsAttention ? .orange : nil))
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.8)
                .textCase(.uppercase)
                .foregroundStyle(.tertiary)
                .accessibilityIdentifier("intake-state-eyebrow")
            RequestDisclosure(intent: intent, expanded: expanded, setExpanded: setExpanded)
            if !summary.isEmpty {
                WrappingRow(spacing: 18, lineSpacing: 4) {
                    ForEach(summary) { item in
                        HStack(spacing: 5) {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.tertiary)
                            Text(item.label).fontWeight(.semibold)
                            if !item.detail.isEmpty { Text(item.detail).foregroundStyle(.secondary) }
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                .font(.callout)
                .padding(.top, 6)
                .accessibilityIdentifier("intake-progress-summary")
            }
        }
    }
}

/// The request's title with a disclosure chevron; open, the title runs on into the rest of the
/// request in regular secondary text, the way an intake row reads (`IntakeRow`), so the first
/// sentence is never shown twice. A request that is one short sentence has nothing more to show,
/// so it is the title alone, with no chevron promising more.
///
/// Collapsed, the chevron and the title are one `Button` — there's nothing to select yet, so the
/// whole row is just a toggle. Open, only the chevron stays a `Button`: a `Button`'s label
/// swallows every click and drag before `.textSelection` ever sees them, so the request text used
/// to sit un-copyable inside it. The text now sits beside the chevron as a plain `Text` with
/// `.textSelection(.enabled)` — the same mechanism the Q&A answers already use — in the same
/// `HStack`, so nothing moves; clicking it no longer collapses the disclosure, only the chevron
/// does.
// Not `private`: `RequestDisclosureTests` instantiates it directly to inspect the view tree a
// real click/drag can reach, which a real AX-tree walk cannot do in a headless test host (see
// that test's header comment).
struct RequestDisclosure: View {
    let intent: String
    let expanded: Bool
    let setExpanded: (Bool) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let parts = IntakeTitle(intent: intent)
        if parts.isWhole {
            title(Text(parts.title))
                .textSelection(.enabled)
        } else if expanded {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Button {
                    if reduceMotion { setExpanded(false) }
                    else { withAnimation(.easeInOut(duration: 0.2)) { setExpanded(false) } }
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(90))
                        .frame(width: 12)
                }
                .buttonStyle(.plain)
                // Enlarges only the hit target, not the layout — the glyph itself stays the same
                // size and position so the row is pixel-identical to the old all-in-one button.
                .contentShape(Rectangle().inset(by: -4))
                .accessibilityLabel(parts.title)
                .accessibilityValue("expanded")
                .accessibilityHint("Hides the rest of the request")
                .accessibilityIdentifier("intake-request")
                title(Text(parts.lead)
                      + Text(" " + parts.rest).font(.body).fontWeight(.regular).foregroundColor(.secondary))
                    .textSelection(.enabled)
                    .accessibilityIdentifier("intake-request-text")
            }
        } else {
            Button {
                if reduceMotion { setExpanded(true) }
                else { withAnimation(.easeInOut(duration: 0.2)) { setExpanded(true) } }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 12)
                    title(Text(parts.title))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(parts.title)
            .accessibilityValue("collapsed")
            .accessibilityHint("Shows the whole request")
            .accessibilityIdentifier("intake-request")
        }
    }

    private func title(_ text: Text) -> some View {
        text
            .font(.title3.weight(.semibold))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .multilineTextAlignment(.leading)
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier("intake-title")
    }
}

/// Every answered exchange, in every state that has one, as a collapsed section — so the Q&A
/// that shaped a recommendation, a plan or a review can be read back from there. Equal while
/// the exchanges and which rounds are open are; `setExpanded` is not compared.
private struct ClarificationsSection: View, Equatable {
    let exchanges: [TriageExchange]
    let expanded: Set<Int>
    let setExpanded: (Int, Bool) -> Void

    static func == (a: Self, b: Self) -> Bool { a.exchanges == b.exchanges && a.expanded == b.expanded }

    var body: some View {
        let _ = RenderProbe.hit("clarifications")
        let answered = exchanges.indices.filter { exchanges[$0].answers != nil }
        if !answered.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Clarifications").font(.headline)
                GroupedRows(count: answered.count) { n in
                    let index = answered[n]
                    DisclosureGroup(isExpanded: Binding(get: { expanded.contains(index) }, set: { setExpanded(index, $0) })) {
                        round(exchanges[index])
                            .padding(.top, 8)
                    } label: {
                        Text(IntakeDetailView.roundLabel(index: index, exchange: exchanges[index]))
                    }
                }
            }
        }
    }

    private func round(_ exchange: TriageExchange) -> some View {
        let answers = exchange.answers ?? []
        return VStack(alignment: .leading, spacing: 12) {
            ForEach(exchange.questions.indices, id: \.self) { i in
                VStack(alignment: .leading, spacing: 3) {
                    Text(exchange.questions[i])
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(i < answers.count ? answers[i] : "—")
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.leading, 18)
    }
}

/// The plan section of the document: its heading, the notes chip, and `PlanSection`. Equal on
/// what it shows — the tape, the round selected, the focus request, the churn cycle — and never on its closures or the service, so an unrelated publish doesn't rebuild the
/// editor's inputs. The notes controller compares by identity: its changes redraw the views
/// observing it, not this one.
private struct DocumentPlan: View, Equatable {
    let service: IntakeService
    let intakeID: UUID
    /// The intake's project directory — what the plan's relative file links open against.
    let projectPath: String
    let title: String
    let tape: Tape
    let final: Bool
    let selection: Int?
    let select: Binding<Int?>
    let focus: PlanFocus?
    let churn: ChurnLaneInput?
    let noteShown: Bool
    let notes: PlanNotesController?
    let onOpenNotes: () -> Void

    static func == (a: Self, b: Self) -> Bool {
        a.intakeID == b.intakeID && a.projectPath == b.projectPath && a.title == b.title && a.tape == b.tape && a.final == b.final
            && a.selection == b.selection && a.focus == b.focus && a.churn?.cycle == b.churn?.cycle
            && a.noteShown == b.noteShown && a.notes === b.notes
    }

    var body: some View {
        let _ = RenderProbe.hit("plan")
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(title).font(.headline)
                Spacer(minLength: 0)
                if let notes { NotesChip(controller: notes, onOpen: onOpenNotes) }
            }
            PlanSection(intakeID: intakeID, tape: tape,
                        loadFile: { [service, intakeID] checkpoint, path in
                            service.checkpointFile(intakeID, checkpoint: checkpoint, path)
                        },
                        onSend: { [service, intakeID] command in service.send(intakeID, command) },
                        selection: select, notes: notes)
                .editHooks(PlanEditHooks(noteShown: noteShown,
                                         onNoteShown: { [service, intakeID] in service.markEditNoteShown(intakeID) },
                                         onConflict: { [service, intakeID] in service.recordEditConflict(intakeID, $0) },
                                         liveTape: { [service, intakeID] in service.tapes[intakeID] },
                                         router: final ? nil : service.editRouter(intakeID),
                                         folds: service.planFolds(intakeID),
                                         projectPath: projectPath))
                .churnLane(churn)
                .focus(focus)
                .readOnly(final)
        }
    }
}

/// What re-reads the review's drift: another intake, or a confirm or drop in the sheet.
private struct ReviewKey: Equatable {
    let id: UUID
    let confirmed: Set<Int>
    let dropped: Set<Int>
}

/// The document's `NSScrollView`, found by `DocumentScrollAnchor` from inside it. A class held
/// in `@State`, so setting it redraws nothing.
final class DocumentScroll {
    weak var view: NSScrollView?
}

/// Sits inside the document and records its enclosing scroll view — the one the pinned block
/// hands wheel events to. Found from inside rather than searched for: the board's tape is a
/// scroll view in the same pane, and a search could land on it.
private struct DocumentScrollAnchor: NSViewRepresentable {
    let scroll: DocumentScroll

    func makeNSView(context: Context) -> AnchorView { AnchorView(scroll: scroll) }
    func updateNSView(_ view: AnchorView, context: Context) {}

    final class AnchorView: NSView {
        let scroll: DocumentScroll
        init(scroll: DocumentScroll) {
            self.scroll = scroll
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let enclosing = enclosingScrollView { scroll.view = enclosing }
        }
    }
}

/// Where a wheel event over the pinned block goes (`WheelToDocument`).
enum WheelRouting {
    /// To the document when it is over the block and not mostly sideways — a sideways one is
    /// the board's tape scrolling along its route. A still event goes too: a trackpad gesture
    /// ends on one, and a scroll view that saw it begin but never end keeps its bounce open.
    static func toDocument(overBlock: Bool, deltaX: CGFloat, deltaY: CGFloat) -> Bool {
        overBlock && abs(deltaY) >= abs(deltaX)
    }
}

/// The pinned block's wheel events, handed to the document's scroll view.
///
/// **Why a monitor, not a `scrollWheel` override.** The block is an overlay beside the document's
/// scroll view, not inside it, and AppKit's hit test over it lands on the pane's hosting view
/// (measured offscreen: every point over the block hit-tested to the `NSHostingView`, never to a
/// view of this block), whose responder chain runs up through its superviews — never down into
/// the scroll view it contains. So no view of the block ever receives the event to forward. A
/// local monitor sees it before the hit test, whichever view it was bound for, and is installed
/// only while the block is on screen.
private struct WheelToDocument: NSViewRepresentable {
    let scroll: DocumentScroll

    func makeNSView(context: Context) -> Forwarder { Forwarder(scroll: scroll) }
    func updateNSView(_ view: Forwarder, context: Context) {}
    static func dismantleNSView(_ view: Forwarder, coordinator: ()) { view.stop() }

    final class Forwarder: NSView {
        let scroll: DocumentScroll
        private var monitor: Any?

        init(scroll: DocumentScroll) {
            self.scroll = scroll
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, let window = self.window, event.window === window, let document = self.scroll.view,
                      WheelRouting.toDocument(overBlock: self.bounds.contains(self.convert(event.locationInWindow, from: nil)),
                                              deltaX: event.scrollingDeltaX, deltaY: event.scrollingDeltaY)
                else { return event }
                document.scrollWheel(with: event)
                return nil
            }
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
    }
}

/// Re-reads only whether the plan is focused, so the inspector switches to the rail and back
/// without the detail pane observing every note keystroke.
private struct PlanFocusReader<Content: View>: View {
    @ObservedObject var notes: PlanNotesController
    @ViewBuilder let content: (Bool) -> Content

    var body: some View { content(notes.planFocused) }
}

/// "4 notes for the next round" beside the plan's heading; opens the rail. Absent with no
/// pending notes (`NotesRailModel.summary`).
private struct NotesChip: View {
    @ObservedObject var controller: PlanNotesController
    let onOpen: () -> Void

    var body: some View {
        if let chip = controller.summary.chip {
            Button(action: onOpen) {
                Text(chip)
                    .font(.system(size: 12))
                    .padding(.horizontal, 9)
                    .frame(height: 22)
                    .notesChipStyle()
            }
            .buttonStyle(.plain)
            .help("Show the notes (⌥⌘I)")
            .accessibilityIdentifier("plan-notes-chip")
        }
    }
}

/// Lays its children out left to right and wraps to a new line when the next one doesn't fit —
/// the header's summary, which at a narrow pane would otherwise truncate the phase it ends on.
private struct WrappingRow: Layout {
    var spacing: CGFloat
    var lineSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        var size = CGSize.zero
        for (i, row) in rows(width: proposal.width ?? .infinity, subviews: subviews).enumerated() {
            var rowWidth: CGFloat = 0
            var rowHeight: CGFloat = 0
            for (j, item) in row.enumerated() {
                rowWidth += item.size.width + (j > 0 ? spacing : 0)
                rowHeight = max(rowHeight, item.size.height)
            }
            size.width = max(size.width, rowWidth)
            size.height += rowHeight + (i > 0 ? lineSpacing : 0)
        }
        return size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            let height = row.map(\.size.height).max() ?? 0
            for item in row {
                item.view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(item.size))
                x += item.size.width + spacing
            }
            y += height + lineSpacing
        }
    }

    private func rows(width: CGFloat, subviews: Subviews) -> [[(view: LayoutSubview, size: CGSize)]] {
        var rows: [[(view: LayoutSubview, size: CGSize)]] = [[]]
        var x: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                rows.append([])
                x = 0
            }
            rows[rows.count - 1].append((view, size))
            x += size.width + spacing
        }
        return rows
    }
}

/// A macOS grouped-form section without `Form`: `Form(.grouped)` is its own scroll view, and
/// nested inside the pane's ScrollView it collapses to no height. Rows sit in one rounded,
/// faintly filled box with inset separators, the way System Settings draws a section.
private struct GroupedRows<Row: View>: View {
    let count: Int
    @ViewBuilder let row: (Int) -> Row

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(0..<count, id: \.self) { i in
                if i > 0 { Divider().padding(.leading, 12) }
                row(i)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(.quinary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.separator))
    }
}
