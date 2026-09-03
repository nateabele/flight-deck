import FleetKit
import SwiftUI

/// One session's conversation. The second of spec §7's three screens.
///
/// **Nothing here implies streaming, for either agent**, and that is a decision rather than
/// an omission. Both agents are read from files they write and neither writes token deltas —
/// see `TimelineItem.Status`, whose `.streaming` case nothing in this codebase emits. So
/// there is no caret, no fading last row and no typing animation. What the screen does show
/// is the truth it has: when the session's `activity` is `busy` or `waiting`, or it is `idle`
/// with `hasBackgroundWork`, a footer says so. That is a claim about the SESSION, which is
/// live, rather than about the last row, which is finished.
///
/// **It follows a live session and opens on the newest message**, which the first version did
/// neither of. A `List` renders oldest-first, so a screen that simply drew the `.latest` page
/// opened on the *oldest* message of the most recent page and then never moved again — two
/// separate ways of showing a reader something that is not what they came for. `follow` below
/// is the rule for both, and it will not take a reader who has scrolled up back down.
struct SessionTimelineScreen: View {
    /// Read from the live fleet rather than captured at push time, so a title change, a
    /// status change or the session closing while this screen is open is visible here too.
    /// `nil` means the fleet no longer lists it — closed on the Mac, or the phone
    /// disconnected before it ever arrived — and every use of it below reads as "then say
    /// nothing about that" rather than as a placeholder.
    let session: WireSession?
    /// **Owned by `FleetModel` and handed in, never constructed here.** A `SessionTimelineModel`
    /// created in this view would be rebuilt on every evaluation of the `navigationDestination`
    /// closure that produces this screen, and each rebuild starts with an empty feed — which
    /// is not merely a re-download, it is a screen that empties itself under the reader.
    /// `FleetModel.timelineModel(for:)` caches one per tab id for exactly that reason.
    let model: SessionTimelineModel
    /// Forwarded straight to `FleetModel.abortBlockedPrompt(session:)` by `FleetListScreen`,
    /// which is the only place in this screen's chain that holds a `FleetModel` at all —
    /// `model` above is deliberately narrowed to the paging/answering protocols, and this one
    /// button's action does not belong on that seam; see `PromptCard.onAbortBlocked`.
    let onAbortBlocked: (UUID) async -> Void

    /// The newest item the screen has already scrolled to, so arriving pages move it once each
    /// rather than on every re-evaluation of the body.
    @State private var lastFollowed: String?
    /// Whether the end of the conversation is on screen. Driven by the sentinel row below
    /// appearing and disappearing, and the only thing that separates "following a live turn"
    /// from "yanking a reader out of the history they scrolled up to read".
    @State private var readerIsAtBottom = true
    /// When the reader last had a finger on the list.
    ///
    /// The sentinel below goes off screen for TWO different reasons and they mean opposite
    /// things: the reader scrolled up into the history (stop following), or a new row was
    /// appended underneath it and pushed it out (keep following — this is the case following
    /// exists for). `onDisappear` alone cannot tell them apart, so it used to treat both as
    /// "the reader left", and the first live message turned following off and left it off
    /// until the reader scrolled back down by hand. This timestamp is what separates them:
    /// only a disappearance the reader's own gesture caused counts.
    @State private var lastReaderScroll: Date = .distantPast
    /// The long answers the reader has opened. **On the screen, not on the row** — see
    /// `Expansion`, which is entirely about why.
    @State private var expansion = Expansion()
    /// Whether the prefetch trigger is on screen, i.e. the reader is within a page of the
    /// oldest history the phone holds. The only thing a failed prefetch can be retried on:
    /// `onAppear` has already fired for a row that is still visible, so without this a read
    /// that failed while the reader sat at the top would never be attempted again.
    @State private var isNearOldest = false
    /// The review the reader is in: built once, in the banner's own `Button` action, and kept
    /// here for as long as the pushed screen is up. `nil` both drives
    /// `.navigationDestination(isPresented:)` and holds what it presents.
    ///
    /// **The MODEL is the state, not the gate it was built from, and that is the whole point.**
    /// `PlanReviewScreen` takes the model rather than owning it, so a model constructed inside
    /// the destination closure would be a *new* one on every evaluation of that closure — and
    /// the feature's own main loop re-evaluates it: a successful comment bumps
    /// `annotationCount`, which changes `session.planGate`, which re-runs this body. Each
    /// rebuild would drop `sent`, the typed `feedback` and the `resolved` latch, so sending one
    /// comment would erase the badge it just earned and the note under it — the same defect
    /// `SessionTimelineModel` is cached in `FleetModel` to avoid (see `model` above, and
    /// `FleetModel.timelineModel(for:)`).
    ///
    /// **Captured at the tap rather than read live from `session?.planGate`** for the second
    /// reason the old `reviewingGate` gave: a live re-read would collapse the pushed screen out
    /// from under a reader still mid-review the instant the Mac's gate clears — which `resolve`
    /// itself causes a heartbeat after the reader's own tap.
    @State private var reviewModel: PlanReviewModel?
    /// The row a search jump landed on, briefly. Mirrors `model.scrollTarget` but fades on its
    /// own clock rather than being cleared by the model, so a reader who lingers keeps seeing
    /// the row that answered their tap for exactly as long as the fade takes and not a frame
    /// longer.
    @State private var highlightedID: String?

    var body: some View {
        ScrollViewReader { scroll in
            List {
                // Notices sit ABOVE the conversation whenever there is a conversation, because
                // the fetch a reader can still trigger with content on screen — returning to a
                // kept screen, which re-reads the live edge — has no row of its own, and the
                // bottom of a long list is somewhere they are not looking. See
                // `topNotice`/`bottomNotice`: exactly one of the two ever answers.
                if let notice = Self.topNotice(
                    phase: model.phase, hasItems: !model.feed.items.isEmpty,
                    isLoadingOlder: model.isLoadingOlder
                ) {
                    noticeRow(notice)
                }
                // Never a control: see `olderStatusRow`. `hasOlder` is what decides, because
                // `olderAnchor` is non-nil at the top of history too.
                if model.feed.hasOlder || model.olderFailure != nil {
                    olderStatusRow
                }
                ForEach(entries) { entry in
                    entryRow(entry)
                        .listRowInsets(Self.rowInsets)
                        // The card and the tinted user turn are what separate one entry from
                        // the next. A hairline through them as well draws a line across the
                        // middle of a rounded panel, which is the same defect that keeps the
                        // fleet list inset-grouped and this list plain.
                        .listRowSeparator(.hidden)
                        // The search-jump highlight. `entry.id == highlightedID` is a plain
                        // comparison, not a fade of its own — the fade is `highlightedID`
                        // being cleared under `withAnimation` in the `onChange` below, and a
                        // `List` row animates a background change on its own.
                        .listRowBackground(
                            entry.id == highlightedID
                                ? Color.accentColor.opacity(0.15) : Color.clear
                        )
                        // **The prefetch trigger, and its depth is the whole design.** It is
                        // NOT the top row: an `onAppear` up there re-fires on every bounce of
                        // an over-scroll and lands its page while the list is still settling,
                        // which drags the reader upward — that defect is why this screen had a
                        // button instead. A page down, the rubber-band never reaches it and
                        // the read finishes before the reader arrives.
                        .onAppear {
                            guard entry.id == prefetchTriggerID else { return }
                            isNearOldest = true
                            model.prefetchOlder()
                        }
                        .onDisappear {
                            if entry.id == prefetchTriggerID { isNearOldest = false }
                        }
                }
                if let notice = Self.bottomNotice(
                    phase: model.phase, hasItems: !model.feed.items.isEmpty
                ) {
                    noticeRow(notice)
                }
                if !model.feed.items.isEmpty, let activity = Self.activityFooter(for: session) {
                    activityRow(activity)
                }
                bottomSentinel
            }
            // `.plain` HERE, unlike the fleet list, and the reason is the content rather than
            // taste: this list holds full-width cards of command output, and inset-grouped's
            // own card edges cut every one of them short and put a second rounded corner
            // inside the first. The fleet list's own comment explains why IT keeps
            // inset-grouped; the two screens differ because what they hold differs.
            .listStyle(.plain)
            // `simultaneousGesture`, so the list keeps scrolling and rows keep taking taps —
            // this only observes. `minimumDistance: 1` because the point is to know a drag
            // happened at all, not to interpret it.
            .simultaneousGesture(
                DragGesture(minimumDistance: 1).onChanged { _ in
                    lastReaderScroll = Date()
                    // The retry, and it is deliberately conditioned on there being something
                    // to retry. Re-arming the prefetch on every drag would let a reader who
                    // rests near the top pull the whole transcript a runway at a time; re-arming
                    // it only after a failure recovers the one case the trigger cannot, at the
                    // cost of nothing when history is arriving normally. `prefetchOlder` clears
                    // the failure as it goes, so this fires once per failure, not once per
                    // frame of the gesture.
                    if isNearOldest, model.olderFailure != nil { model.prefetchOlder() }
                }
            )
            // `initial: true` so the first page a screen ever draws is followed too. Without
            // it the jump only happens on the SECOND page, and opening a session lands on the
            // oldest row of the newest page — which is what shipped.
            .onChange(of: model.feed.items.last?.id, initial: true) { _, newest in
                guard let target = Self.follow(
                    newest: newest, lastFollowed: lastFollowed,
                    readerIsAtBottom: readerIsAtBottom
                ) else { return }
                let isFirst = lastFollowed == nil
                lastFollowed = target
                // Next run-loop turn, because the row being scrolled to is inserted by this
                // same change and a `List` has not laid it out yet when `onChange` runs.
                DispatchQueue.main.async {
                    // **Unanimated, including when following a live turn.** The previous
                    // version animated everything but the opening jump, on the reasoning that
                    // "there the movement is the information". It did not scroll at all.
                    //
                    // A console trace of three consecutive follows settled it: `follow()`
                    // returned SCROLL for every one of them with `atBottom=true`, so the
                    // decision was never in question — but only the FIRST, the unanimated
                    // opening jump, was followed by the bottom sentinel reappearing. The
                    // animated ones produced no `onAppear` at all, which is the sentinel
                    // saying the list never moved. `withAnimation` around `scrollTo`, in a
                    // lazy `List` whose target row was de-materialised by the same insertion
                    // that triggered this, silently does nothing.
                    // A SECOND hop before scrolling at all. The row this change inserted is
                    // not laid out when `onChange` runs, and one hop is not always enough —
                    // scrolling to a row `List` has not placed yet is what silently did
                    // nothing when this was first written.
                    DispatchQueue.main.async {
                        // Animated again, deliberately. An earlier version dropped the
                        // animation because animated follows were not moving the list at all,
                        // but the console trace that showed this could not separate "animated"
                        // from "single hop": the one call that worked was ALSO the only
                        // unanimated one AND the only whole-page open rather than a one-row
                        // append. The extra hop above addresses the layout half; the animation
                        // stays because a list that jumps loses the reader's place.
                        withAnimation(isFirst ? nil : .easeOut(duration: 0.25)) {
                            scroll.scrollTo(Self.bottomAnchor, anchor: .bottom)
                        }
                        // The net, and it is why the animation is safe to keep. If the
                        // animated scroll no-ops the way it used to, this lands it anyway a
                        // third of a second later. When the animation DID work this is a
                        // scroll to where the list already is, which is invisible — so the
                        // failure mode is a late snap instead of never arriving.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                            scroll.scrollTo(Self.bottomAnchor, anchor: .bottom)
                        }
                    }
                }
            }
            // A search jump. `model.scrollTarget` is set exactly once per `.around` fetch that
            // lands (see `SessionTimelineModel.fetch`), so this fires once per tap on a
            // transcript result rather than on every re-render.
            .onChange(of: model.scrollTarget) { _, target in
                guard let target else { return }
                // Two hops, the same reason as the follow-to-bottom jump above: the row this
                // targets was inserted by the very fetch that set `scrollTarget`, and `List`
                // has not laid it out yet when `onChange` runs.
                DispatchQueue.main.async {
                    DispatchQueue.main.async {
                        withAnimation { scroll.scrollTo(target, anchor: .center) }
                    }
                }
                highlightedID = target
                Task {
                    try? await Task.sleep(for: .milliseconds(1_500))
                    // `fadedHighlight` owns the guard against a second jump landing while the
                    // first is still fading — see its own doc comment.
                    withAnimation(.easeOut(duration: 0.4)) {
                        highlightedID = Self.fadedHighlight(current: highlightedID, target: target)
                    }
                }
            }
        }
        .navigationTitle(session?.title ?? "Session")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(for: TimelineItem.self) { item in
            TimelineItemDetailScreen(
                item: item,
                result: Self.pairedResult(for: item, in: model.feed.items),
                agent: session?.agent
            )
        }
        // A second `.navigationDestination`, keyed on presence rather than on a value: this
        // is a `PlanReviewModel` and the `for:` form above needs a `Hashable` value to match a
        // pushed item back to its case. `reviewModel` is both the trigger and the payload,
        // built once at the tap; see its own comment for why the destination READS a model it
        // does not build, and why the gate behind it is captured rather than read live.
        .navigationDestination(isPresented: Binding(
            get: { reviewModel != nil },
            set: { isPresented in if !isPresented { reviewModel = nil } }
        )) {
            if let reviewModel {
                PlanReviewScreen(model: reviewModel)
            }
        }
        // Keyed on the session, not on nothing: a `.task` re-firing over the SAME model is
        // harmless by construction — `loadLatest` asks `feed.newerAnchor`, which is
        // `.after(newest)` on a feed that holds anything, so returning to a loaded screen
        // picks up what is new instead of merging a `.latest` page over the top and leaving
        // an invisible hole in the middle. What must NOT happen is this firing against a
        // model belonging to a different session, and the id is what rules that out.
        //
        // `open()` rather than `loadLatest()`: this is also the moment the session counts as
        // looked at, and it is the ONLY place that says so — the fleet list's row used to
        // send the mark from a gesture racing its own link, which is what stopped rows
        // opening at all. See `TimelinePaging`.
        .task(id: model.sessionID) { model.open() }
        // Reported from the SCREEN rather than the model: the model is cached per tab and
        // outlives the screen (see `FleetModel.timelineModel(for:)`), so tying presence to its
        // lifetime would leave a badge glowing for a conversation nobody is looking at.
        .onAppear { model.viewing(true) }
        .onDisappear { model.viewing(false) }
        // `safeAreaInset`, not a row in the `List` and not an overlay: the inset is what
        // reserves height so the last line of the conversation is not covered, and it is what
        // rides above the keyboard when the field takes focus. A row would scroll away from
        // the person typing into it — and it would also scroll away from `bottomSentinel`,
        // which is how this screen knows whether the reader is at the live edge.
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 0) {
                // The card and the composer are one inset, in that order: the dialog the agent
                // is blocked on sits directly above the field, so a reader whose keyboard is up
                // can still see what they are answering.
                PromptCard(
                    open: model.blocked(
                        agent: session?.agent, activity: session?.activity,
                        call: session?.openPromptCall ?? .unreported
                    ),
                    agent: session?.agent,
                    state: model.answerState,
                    model: model,
                    blockedChaseExhausted: model.blockedChaseExhausted,
                    allowsBlockedAbort: session?.allowsBlockedAbort ?? false,
                    onAbortBlocked: { await onAbortBlocked(model.sessionID) }
                )
                PromptComposer(session: session, model: model)
            }
        }
        // The top inset, and the reason it exists at all: `ExitPlanMode` is the one tool call
        // a hook blocks WITHOUT claude ever reporting `waiting` (see `ClaudeOpenPlanGate`'s own
        // comment), so a session gated on a plan draws no `PromptCard` at the bottom of this
        // screen and no waiting badge in the fleet list either — nothing on either screen says
        // anything is happening. `session?.planGate` is the one signal that survives that gap,
        // and this banner is what "replaces a spinner that says nothing" (spec's own words).
        .safeAreaInset(edge: .top) {
            if let gate = session?.planGate {
                planGateBanner(gate)
            }
        }
        // The event trigger. `activity` and the title change live on the fleet socket, and a
        // change to either is the cheapest possible signal that this session has moved — most
        // importantly the busy → idle transition, which is the moment the last records of a
        // turn have landed.
        .onChange(of: session?.activity) { _, _ in model.loadNewer() }
        // The second event trigger, and it fires where the first cannot. A dialog answered at
        // the keyboard with the next one raised immediately never leaves `waiting`, so
        // `activity` is identical either side of it and the modifier above sees nothing — the
        // stale-card report, exactly. Which call is open does move, so this is the fetch that
        // brings the records naming the new dialog. Until they land `blocked` draws nothing,
        // which is the honest state rather than the previous dialog's buttons.
        .onChange(of: session?.openPromptCall) { _, _ in model.loadNewer() }
        // The timer, and it is not redundant with the event above: `emitActivity` on the Mac
        // filters to genuine transitions, so a turn that runs busy for four minutes emits
        // NOTHING in the middle of it. Without this, an open screen would sit unchanged
        // through the whole turn and then fill in at the end.
        //
        // Only while busy, and only while the screen is on top: `.task` cancels on disappear,
        // so an idle session and a backgrounded screen both cost nothing. The interval is a
        // compromise a reader will accept — 1.5s is a beat behind a terminal and cheap enough
        // that a page of nothing new is a handful of bytes.
        .task(id: session?.activity) {
            guard session?.activity == "busy" else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(1_500))
                guard !Task.isCancelled else { return }
                model.loadNewer()
            }
        }
        // **The chase for what this session is blocked ON**, and it exists for one race: the
        // status file and the transcript are written by independent paths in claude, so
        // `waiting` can reach the phone before the record that names the dialog.
        //
        // This was a single deferred fetch, and the checklist did find it flaky — exactly as
        // the comment here used to predict. One shot was not enough, because losing it is
        // terminal: a waiting session emits no further activity change, the busy poll below
        // runs only while `busy`, and nothing else ever asks again. The session sat saying
        // "Waiting for you" with no card under it. The answer is a bounded, backing-off chase
        // that stops the moment the card can be drawn — see `chaseBlockedPrompt`, which is
        // where the reasoning and the bound live, and which is on the model so it can be
        // tested rather than eyeballed.
        //
        // A separate `.task(id:)` from the busy poll above rather than a branch inside it: two
        // modifiers with the same id both run, and merging them would tie two different
        // cadences — a 1.5s follow and this — to one decision.
        //
        // Keyed on the dialog as well as the activity: a supersede leaves `activity` untouched,
        // so an id of `activity` alone would not restart the chase for the dialog that
        // replaced it — the card would stay blank until something else happened to move.
        .task(id: BlockedState(session)) {
            guard session?.activity == "waiting" else { return }
            await model.chaseBlockedPrompt(
                agent: session?.agent, activity: session?.activity,
                call: session?.openPromptCall ?? .unreported
            )
        }
    }

    /// Matches the fleet list's leading inset, so the two screens' left edges line up when one
    /// pushes the other. Taller than that list's, because these rows are cards rather than
    /// single lines and a card needs air around it to read as one object.
    private static let rowInsets = EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16)

    /// The id of the row that marks the end of the conversation.
    private static let bottomAnchor = "timeline.bottom"

    /// How recently the reader must have touched the list for the sentinel going off screen
    /// to count as them leaving the live edge. Long enough to cover the lag between a finger
    /// moving and a 1-point row clearing the viewport, short enough that a message arriving a
    /// moment after an unrelated tap-drag is still followed.
    private static let scrollGestureWindow: TimeInterval = 1

    /// A zero-height row at the very end, and it does two jobs that both need something to
    /// exist down there: it is what `scrollTo` aims at — the last *entry* is the wrong target,
    /// since a tall card scrolled to its own bottom still leaves the footer off screen — and
    /// its appearing and disappearing is how the screen knows whether the reader is at the
    /// live edge or up in the history.
    private var bottomSentinel: some View {
        Color.clear
            .frame(height: 1)
            .id(Self.bottomAnchor)
            .listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
            .accessibilityHidden(true)
            .onAppear { readerIsAtBottom = true }
            // Gated on a recent gesture — see `lastReaderScroll`. A sentinel pushed off the
            // bottom by the very row we are about to follow to must NOT count as the reader
            // leaving, or following stops on the first message it was supposed to follow.
            .onDisappear {
                if Date().timeIntervalSince(lastReaderScroll) < Self.scrollGestureWindow {
                    readerIsAtBottom = false
                }
            }
    }

    private var entries: [Entry] { Self.entries(from: model.feed.items) }

    /// One entry, as a link into the detail screen or as a row that is simply itself.
    ///
    /// **A `NavigationLink` only where there is something to navigate to**, which is
    /// `TimelineStyle.opensDetail(_:)` and nothing else. A prose row now draws its message
    /// whole, so the screen one tap away would repeat it word for word — and a `List` puts a
    /// disclosure chevron on every link it holds, floated at the row's vertical centre. On a
    /// forty-line answer that chevron sits twenty lines down, pointing at nothing, promising
    /// a screen that has nothing more on it. The renders in
    /// `.superpowers/sdd/ui-renders/prose-full/` are what settled that.
    ///
    /// The rows that keep the link keep it because they really are showing less than they
    /// have AND have no way to show it here: a tool card's three-line command and six-line
    /// output, a clamped thinking block, a JSON input worth a tree. **A prose body past the
    /// ceiling is no longer among them** — it opens where it stopped instead, which is also
    /// what makes its More button tappable: a `NavigationLink` swallows the tap on any control
    /// inside it, so a row cannot be a link and carry a button at once.
    @ViewBuilder
    private func entryRow(_ entry: Entry) -> some View {
        let row = TimelineRow(
            item: entry.item, result: entry.result, agent: session?.agent,
            isExpanded: expansion.isExpanded(entry.id),
            // Not animated, and that is the same judgement the opening jump above is made on:
            // a row growing by two thousand points is not a transition anything can follow,
            // and `List` animating a height change that large under the finger reads as the
            // screen having lost its place. The rest of the message is simply there.
            toggleExpanded: { expansion.toggle(entry.id) },
            // Straight onto the model, which is where the draft lives — the row never learns
            // that a composer exists.
            onReply: { model.quote($0) }
        )
        if TimelineStyle.opensDetail(entry.item) {
            NavigationLink(value: entry.item) { row }
        } else {
            row
        }
    }

    /// What sits above the oldest row the phone holds: a spinner while history is on its way,
    /// the reason if the last read of it failed, and **nothing at all** once the beginning of
    /// the conversation is reached.
    ///
    /// **Not a button, and that is the point of this whole change.** It used to be one — "Load
    /// earlier" — on the reasoning that an automatic fetch fires on over-scroll bounce and
    /// drags the reader upward, and that an explicit tap puts them in charge of where they
    /// are. Both halves of that were true and the conclusion was still wrong: it made every
    /// trip into history a tap followed by a wait, on a screen whose entire job is reading.
    /// The fetch is now started a page early by the trigger in the list body, so by the time
    /// the reader gets here the rows are usually already in place and this row is not drawn at
    /// all. What is left of it is a report, never a control — there is nothing here to press,
    /// and nothing that fails to load leaves the reader with a decision to make.
    ///
    /// The failure is shown without a retry for the same reason: `prefetchOlder` is re-armed
    /// by the reader's next scroll near the top, so the recovery is the gesture they were
    /// already making.
    @ViewBuilder
    private var olderStatusRow: some View {
        HStack(spacing: 6) {
            Spacer(minLength: 0)
            if let failure = model.olderFailure {
                Image(systemName: "exclamationmark.triangle.fill").font(.caption2)
                Text(failure)
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ProgressView().controlSize(.small)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
        .foregroundStyle(.secondary)
        // Stated rather than left to the content: half the time the content is a
        // `ProgressView`, which announces nothing, and a reader on VoiceOver arriving at the
        // top of what has loaded would be told only that the conversation ends there.
        .accessibilityLabel(model.olderFailure ?? "Loading earlier messages")
        .listRowInsets(Self.rowInsets)
        .listRowSeparator(.hidden)
    }

    /// The entry whose appearance starts the next read of history, or `nil` when there is no
    /// history left to read.
    private var prefetchTriggerID: String? {
        model.feed.hasOlder ? Self.prefetchTrigger(entries) : nil
    }

    /// How far below the oldest loaded row the trigger sits, in entries.
    ///
    /// One page's worth. Shallower and the rubber-band at the top of the list starts reaching
    /// it — the defect that made this a button in the first place. Deeper and it fires while
    /// the reader is still in the middle of what they have, which is a read they may never
    /// need. `defaultLimit` is in *records* and one record can carry several entries, so this
    /// is a floor on the real distance rather than an estimate of it.
    static let prefetchDepth = TimelineLimits.defaultLimit

    /// **Falls back to the OLDEST entry, and the direction is the trap.** `entries` is
    /// oldest-first, so the trigger's index counts down from the top of history: index
    /// `prefetchDepth` is the row with a page of history above it. A feed shorter than that
    /// has no such row — and clamping the index to `count - 1` picks the *newest* row instead,
    /// which fires the read the instant the screen draws and every time the reader returns to
    /// the bottom. The fallback has to be index 0: on a feed this short there is no runway to
    /// be had, so the earliest possible ask is the right one.
    ///
    /// Not `nil`, which is what an unclamped lookup answers: a screen that loaded one short
    /// page would then never ask for a second, and those are exactly the sessions where the
    /// reader reaches the top fastest.
    static func prefetchTrigger(_ entries: [Entry]) -> String? {
        guard !entries.isEmpty else { return nil }
        return entries.count > prefetchDepth ? entries[prefetchDepth].id : entries[0].id
    }

    // MARK: One entry per thing that happened

    /// A row's worth of conversation: an item, plus the result that answers it when the item
    /// is a call and the feed holds one.
    struct Entry: Identifiable, Hashable {
        let item: TimelineItem
        let result: TimelineItem?
        var id: String { item.id }
    }

    // MARK: Which long answers are open

    /// The set of rows the reader has opened past the ceiling, by entry id.
    ///
    /// **It lives on the SCREEN rather than on the row, and the usual argument for that is not
    /// the reason.** The usual argument is that a lazy `List` tears a row out of the view tree
    /// and rebuilds it, so a row-owned `@State` would be lost on a scroll. That was measured
    /// here and it is **not true on this SwiftUI**: `ProseExpansionRecyclingTests` scrolls a row
    /// six thousand points away and back at 30, 200 and 600 rows, and a probe row's own `@State`
    /// survives every time — the cell is recycled, the state box is kept — and survives the row
    /// leaving the feed outright as well.
    ///
    /// What the placement buys is two things that do not depend on that behaviour. A row is a
    /// pure function of the flag it is handed, so no `List` behaviour — this one or a future
    /// one — can reach the reader's answer to the ceiling; this screen is one view on a
    /// navigation stack and outlives every row that reads it. And a decision reachable without
    /// SwiftUI is a decision a test can run, which is the same rule `TimelineStyle` is written
    /// under: `TimelineProseExpansionTests` drives every transition below with no window at all.
    ///
    /// Keyed by `Entry.id`, which is `TimelineItem.id`: the record's byte offset in the file
    /// the agent wrote, so it is stable across every refetch and re-page. An id that leaves the
    /// feed leaves a `String` in a set behind it, which costs nothing and is what makes paging
    /// away from an open row and back the same case as scrolling.
    ///
    /// A value type rather than an observable object, so a change to it invalidates the screen
    /// the ordinary way and a test can drive it with no view at all.
    struct Expansion: Equatable {
        private var open: Set<String> = []

        /// Collapsed until the reader says otherwise: a row that opened itself would put the
        /// ceiling back where it was.
        func isExpanded(_ id: String) -> Bool { open.contains(id) }

        /// One control, both directions — More opens and Less shuts, so a reader who has
        /// finished with an answer can put four screenfuls of it away again.
        mutating func toggle(_ id: String) {
            if open.contains(id) { open.remove(id) } else { open.insert(id) }
        }
    }

    /// Folds every tool result into the call it answers, so a command and its output are one
    /// card rather than two rows that read as two unrelated events.
    ///
    /// **Paired on `callID` — the agent's own id — and never on position.** A session running
    /// two tools at once interleaves their records, so "the next result" is a different call's
    /// output about half the time, and a command captioned with another command's output is
    /// worse than a command with no output shown at all.
    ///
    /// **A result is only folded away when its call is actually here.** A page boundary can
    /// land between the two, and dropping a result whose call is on the previous page would
    /// delete content from the screen — the one thing worse than showing it twice. So the set
    /// of calls present is what decides, not merely the result having an id.
    static func entries(from items: [TimelineItem]) -> [Entry] {
        var resultsByCall: [String: TimelineItem] = [:]
        var callsPresent: Set<String> = []
        for item in items {
            guard let callID = item.body.callID else { continue }
            switch item.kind {
            case .toolResult: if resultsByCall[callID] == nil { resultsByCall[callID] = item }
            case .toolCall: callsPresent.insert(callID)
            default: break
            }
        }
        return items.compactMap { item in
            guard let callID = item.body.callID else { return Entry(item: item, result: nil) }
            switch item.kind {
            case .toolCall:
                return Entry(item: item, result: resultsByCall[callID])
            case .toolResult:
                return callsPresent.contains(callID) ? nil : Entry(item: item, result: nil)
            default:
                return Entry(item: item, result: nil)
            }
        }
    }

    // MARK: Following the live edge

    /// The row to scroll to when the conversation changes, or `nil` to leave the reader alone.
    ///
    /// Three rules, and the third is the one with a defect behind it. The first page is always
    /// followed, because a `List` draws oldest-first and the `.latest` page's newest record is
    /// off the bottom of the screen — "opens on the most recent messages" is otherwise simply
    /// false. Later pages are followed only while the end of the conversation is already on
    /// screen. A reader who has scrolled up into the history is left exactly where they are:
    /// a 1.5s poll that scrolled the list under them would make reading a finished turn
    /// impossible for as long as the next one runs.
    ///
    /// `lastFollowed` is what stops a re-evaluated body from re-scrolling to a row it already
    /// moved to, which reads as a list that fights the reader's finger.
    static func follow(newest: String?, lastFollowed: String?, readerIsAtBottom: Bool) -> String? {
        guard let newest, newest != lastFollowed else { return nil }
        guard lastFollowed != nil else { return newest }
        return readerIsAtBottom ? newest : nil
    }

    // MARK: A search jump's fading highlight

    /// What `highlightedID` becomes when a search jump's 1.5s fade timer fires, `target` being
    /// the row that timer was armed for.
    ///
    /// **Owns the guard against a second jump landing mid-fade.** Both jumps write the same
    /// `highlightedID`, so a timer that always cleared it would let the FIRST jump's timer
    /// erase the SECOND jump's highlight — the reader taps a second result while the first is
    /// still fading, and the row they just landed on goes dark under a timer that isn't even
    /// its own. Clearing only when `current` still equals the timer's own `target` is what
    /// keeps a later jump's highlight alive until ITS OWN timer fires.
    static func fadedHighlight(current: String?, target: String) -> String? {
        current == target ? nil : current
    }

    /// What the screen says about a fetch. Three phases, but the same phase means different
    /// things depending on whether there is anything on screen, which is the whole reason
    /// this is decided in one place instead of inline in the `List`.
    enum Notice: Equatable {
        /// A first fetch, with nothing to show while it runs.
        case loading
        /// The fetch succeeded and the conversation is empty. **Never shown while one is
        /// running** — an empty state that appears during a fetch claims a session has no
        /// history when the page simply has not landed.
        case empty
        /// The session has been created and its agent has not taken a turn yet. Separate from
        /// `empty` because they are true at different moments and only one of them ends by
        /// itself, and separate from `failed` because nothing has gone wrong.
        case notStarted
        case failed(String)
    }

    /// The notice that belongs above the conversation, or `nil` for none.
    ///
    /// **This is where a failure lands once there is content**, and the placement is the
    /// point. `SessionTimelineModel` only reaches `.failed` from a fetch the reader caused,
    /// and with content already on screen that means returning to a kept screen, whose
    /// `loadLatest` re-reads the live edge — the deadline makes a dead link a *fifteen second*
    /// gap before anything is said. Putting the reason at the bottom of a list the reader has
    /// scrolled to the top of is the same defect as a spinner that never ends: the spinner
    /// stops, and nothing they can see says why.
    ///
    /// **A failed prefetch is not one of these** and must never become one: it reports itself
    /// in `olderFailure`, above the oldest row, precisely so a read nobody asked for cannot
    /// put an error at the top of a conversation that is still perfectly readable.
    ///
    /// Suppressed while `isLoadingOlder`, because `phase` keeps the last failure until a
    /// fetch succeeds: a read of history would otherwise run underneath the stale explanation
    /// of an attempt before it.
    static func topNotice(
        phase: SessionTimelineModel.Phase, hasItems: Bool, isLoadingOlder: Bool
    ) -> Notice? {
        guard hasItems, !isLoadingOlder, case .failed(let message) = phase else { return nil }
        return .failed(message)
    }

    /// The notice that belongs below the conversation, or `nil` for none — which, with any
    /// content at all, is always: the top row has it. This is the empty screen's whole story,
    /// and the three cases are three different screens that must not be collapsed into one
    /// blank list.
    static func bottomNotice(phase: SessionTimelineModel.Phase, hasItems: Bool) -> Notice? {
        guard !hasItems else { return nil }
        switch phase {
        case .loading:
            return .loading
        case .notStarted:
            return .notStarted
        case .failed(let message):
            return .failed(message)
        case .idle:
            return .empty
        }
    }

    /// The three empty screens, drawn as screens rather than as a grey line of footnote text.
    /// Each one is the *only* thing a reader sees when it appears, and a sentence flush against
    /// the navigation bar with nothing else on the page reads as a rendering failure.
    @ViewBuilder
    private func noticeRow(_ notice: Notice) -> some View {
        switch notice {
        case .loading:
            VStack(spacing: 10) {
                ProgressView()
                Text("Loading conversation…").font(.footnote).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 220)
            .listRowInsets(Self.rowInsets)
            .listRowSeparator(.hidden)
        case .empty:
            ContentUnavailableView(
                "No messages yet",
                systemImage: "bubble.left.and.bubble.right",
                description: Text("This session hasn't said anything your Mac can read yet.")
            )
            .listRowInsets(Self.rowInsets)
            .listRowSeparator(.hidden)
        case .notStarted:
            // **No Try again here, and that absence is the fix.** This is what every session
            // looks like between being created and taking its first turn, and it used to draw
            // the failure notice — a warning triangle and a retry button, over a session where
            // nothing had gone wrong and where the button re-asked a question the Mac had
            // already answered correctly. What ends this state is the agent taking a turn, and
            // the composer for that is directly below.
            ContentUnavailableView(
                "Nothing here yet",
                systemImage: "bubble.left",
                description: Text("This session hasn't taken its first turn.")
            )
            .listRowInsets(Self.rowInsets)
            .listRowSeparator(.hidden)
        case .failed(let message):
            failureNotice(message)
        }
    }

    /// The reason, and a way to try again.
    ///
    /// **The button used to be withheld when there was content on screen**, on the reasoning
    /// that the failure was almost always the "Load earlier" tap and that button was the row
    /// directly below this one — so a second control doing the same job one row apart was how
    /// a reader ended up re-issuing a fetch they could not see the state of. That row is gone
    /// now, and with it the argument: `phase` can only reach `.failed` from a fetch the reader
    /// caused, a prefetch reports itself in `olderFailure` instead, and withholding the button
    /// here would leave a reader who returned to a screen that failed to re-read the live edge
    /// with nothing to touch at all.
    private func failureNotice(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Try again") { model.loadLatest() }
                .font(.footnote.weight(.medium))
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
        .listRowInsets(Self.rowInsets)
        .listRowSeparator(.hidden)
    }

    /// The two fields a blocked card is a function of, as one `.task(id:)` key.
    ///
    /// A struct because `.task(id:)` takes one value and these move independently: entering
    /// and leaving `waiting` is one axis, and *which* dialog is up is the other — the axis a
    /// supersede moves alone, and the reason a chase keyed on `activity` never restarted for
    /// the dialog that replaced the one a reader was looking at.
    private struct BlockedState: Equatable {
        let activity: String?
        let call: OpenPromptIdentity

        init(_ session: WireSession?) {
            activity = session?.activity
            call = session?.openPromptCall ?? .unreported
        }
    }

    /// The only live claim on the screen, and it is about the session rather than about the
    /// last row — see this type's own comment.
    enum Activity: Equatable {
        case working(String)
        case waiting(String)
        /// `idle` with `hasBackgroundWork` — a turn that finished with a task still running
        /// underneath it. Its symbol and tint match the fleet list's badge, not `working`'s
        /// spinner: nothing is running the model turn, only the background task is.
        case background(String)
    }

    /// What the session itself is doing, said the way the Mac says it.
    ///
    /// **The text is `SessionStatusGlyph.label(for:)`'s, not recomputed here.** An earlier
    /// version of this function reimplemented the subagent-count and waiting-reason
    /// formatting independently — the same values, worded by two functions instead of one —
    /// which is exactly how the background-work clause first shipped on the fleet list here
    /// but not here: a second implementation is a second place to forget to update it. Calling
    /// through means every clause `label(for:)` composes, including the background one,
    /// reaches this footer for free.
    ///
    /// `idle` only produces a footer when `hasBackgroundWork` is set: a quiet idle session has
    /// nothing live to say at the foot of a conversation, but "idle with a background command
    /// still running" is the one state this whole feature exists to surface, and staying
    /// silent about it here after showing a badge in the fleet list would tell a reader two
    /// different stories about the same session two taps apart.
    static func activityFooter(for session: WireSession?) -> Activity? {
        guard let session, let label = SessionStatusGlyph.label(for: session) else { return nil }
        switch session.activity {
        case "busy":
            return .working(label)
        case "waiting":
            return .waiting(label)
        case "idle":
            return session.hasBackgroundWork ? .background(label) : nil
        default:
            // An activity this build has never heard of still gets a label (see `label(for:)`'s
            // own fallback), but it is not something live to announce at the foot of a
            // conversation.
            return nil
        }
    }

    /// Same symbol and same tint as the fleet list's glyph for the same three states, because
    /// a reader arrives here from that row and the two screens describing one session
    /// differently is the disagreement `SessionStatusGlyph`'s comment exists to prevent.
    @ViewBuilder
    private func activityRow(_ activity: Activity) -> some View {
        switch activity {
        case .working(let text):
            HStack(spacing: 8) {
                ProgressView().controlSize(.mini)
                Text(text).font(.footnote)
                Spacer(minLength: 0)
            }
            .foregroundStyle(.secondary)
            .padding(.vertical, 8)
            .listRowInsets(Self.rowInsets)
            .listRowSeparator(.hidden)
        case .waiting(let text):
            Label(text, systemImage: "questionmark.circle.fill")
                .font(.footnote)
                .foregroundStyle(.orange)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .listRowInsets(Self.rowInsets)
                .listRowSeparator(.hidden)
        case .background(let text):
            Label(text, systemImage: "terminal.fill")
                .font(.footnote)
                .foregroundStyle(.green)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .listRowInsets(Self.rowInsets)
                .listRowSeparator(.hidden)
        }
    }

    /// The result that answers a tool call, when the feed happens to hold it, so the detail
    /// screen can show a command and its output together.
    ///
    /// **Matched on `callID` — the agent's own id — and never on `id`, which is a byte offset
    /// and pairs nothing.** Nor is it "the next result in the feed": a session that runs two
    /// tools at once interleaves their records, and taking the first `.toolResult` found
    /// would caption one command with another one's output, which is worse than showing no
    /// output at all. A call whose result has not arrived yet, and a call the agent gave no
    /// id for, both get `nil` rather than a guess.
    static func pairedResult(for item: TimelineItem, in items: [TimelineItem]) -> TimelineItem? {
        guard item.kind == .toolCall, let callID = item.body.callID else { return nil }
        return items.first { $0.kind == .toolResult && $0.body.callID == callID }
    }

    // MARK: The plan gate

    /// The review one tap opens: the gate the banner was drawn for, and the plan behind it.
    ///
    /// **Called from the tap and nowhere else** — see `reviewModel`, which keeps what this
    /// returns. Building it is destructive by nature: a `PlanReviewModel` carries everything the
    /// reader has done on the pushed screen, so a second call replaces all of it.
    ///
    /// `transcriptPlan` is resolved here, at the tap, for the same reason the gate is: it reads
    /// `feed.items`, which keeps arriving while the reader is on the pushed screen, and the plan
    /// under review is the one the banner was tapped for.
    @MainActor
    static func review(of gate: WirePlanGate, in model: SessionTimelineModel) -> PlanReviewModel {
        PlanReviewModel(
            session: model.sessionID,
            gate: gate,
            transcriptPlan: transcriptPlan(for: gate, in: model.feed.items),
            send: { model.sendPlanCommand($0) }
        )
    }

    /// The whole banner: what it is waiting on, and how long it has been. A `Button` rather
    /// than a `NavigationLink(value:)` for the same reason the destination below is keyed on
    /// `isPresented` rather than `for:` — neither `WirePlanGate` nor `PlanReviewModel` is
    /// `Hashable` — and the tap is what BUILDS the review, once, rather than the destination
    /// building a fresh one on every evaluation and the reader losing what they wrote into it.
    private func planGateBanner(_ gate: WirePlanGate) -> some View {
        Button {
            reviewModel = Self.review(of: gate, in: model)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.title3)
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Waiting on your review of a plan")
                        .font(.subheadline.weight(.semibold))
                    if let elapsed = Self.elapsedText(since: gate.startedAt) {
                        Text(elapsed)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemBackground))
        }
        .buttonStyle(.plain)
    }

    /// "Started 5 minutes ago" from the gate's own `startedAt`, or `nil` when the timestamp
    /// cannot be parsed — the banner still reads correctly with just its headline in that case.
    ///
    /// Its own ISO8601 fallback rather than a call into `TimelineStyle.date(_:)`: that helper
    /// is `private` to that file, and this is the only other place in the app that needs to
    /// parse a wire timestamp, so a second two-formatter pair (fractional seconds, then
    /// without) is the smaller duplication.
    static func elapsedText(since startedAt: String) -> String? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let whole = ISO8601DateFormatter()
        whole.formatOptions = [.withInternetDateTime]
        guard let date = withFraction.date(from: startedAt) ?? whole.date(from: startedAt)
        else { return nil }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return "Started " + formatter.localizedString(for: date, relativeTo: Date())
    }

    /// The `verdict` tier's plan source. There the gate itself carries none (see
    /// `WirePlanGate.plan`'s own comment), so this reads `ExitPlanMode`'s own `input.plan` out
    /// of the timeline body the phone already holds — the very call the gate names by
    /// `callID`, so there is no question of which among several plan-shaped calls this is for.
    ///
    /// Informed by, but not reusing, `ClaudeOpenPlanGate.find` on the Mac: that walks raw
    /// transcript lines looking for the newest UNANSWERED `ExitPlanMode` call, because it is
    /// the one deciding whether a gate is open at all. This is only ever asked about a call the
    /// Mac has already told the phone is open, against `TimelineItem`s the feed already holds
    /// — so matching directly on `callID` is enough; there is no "which one is newest" left to
    /// resolve. `nil` both when the call has not reached this feed's window and when its body
    /// does not parse, and either way `PlanReviewModel` falls back to an empty plan rather than
    /// crashing on it.
    static func transcriptPlan(for gate: WirePlanGate, in items: [TimelineItem]) -> String? {
        guard let call = items.first(where: {
            $0.kind == .toolCall && $0.body.tool == "ExitPlanMode" && $0.body.callID == gate.callID
        }) else { return nil }
        guard let document = TimelineStyle.jsonDocument(for: call),
              case .object(let members) = document,
              case .string(let plan) = members.first(where: { $0.key == "plan" })?.value
        else { return nil }
        return plan
    }
}
