import FleetKit
import SwiftUI

/// One session's conversation. The second of spec §7's three screens.
///
/// **Nothing here implies streaming, for either agent**, and that is a decision rather than
/// an omission. Both agents are read from files they write and neither writes token deltas —
/// see `TimelineItem.Status`, whose `.streaming` case nothing in this codebase emits. So
/// there is no caret, no fading last row and no typing animation. What the screen does show
/// is the truth it has: when the session's `activity` is `busy`, a footer says the agent is
/// working. That is a claim about the SESSION, which is live, rather than about the last row,
/// which is finished.
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

    var body: some View {
        ScrollViewReader { scroll in
            List {
                // Notices sit ABOVE the conversation whenever there is a conversation, because
                // the only fetch a reader can trigger with content on screen is "Load earlier",
                // and the bottom of a long list is somewhere they are not looking. See
                // `topNotice`/`bottomNotice`: exactly one of the two ever answers.
                if let notice = Self.topNotice(
                    phase: model.phase, hasItems: !model.feed.items.isEmpty,
                    isLoadingOlder: model.isLoadingOlder
                ) {
                    noticeRow(notice)
                }
                // **Both conditions belong to the feed, and `hasOlder` is the one that decides.**
                // `olderAnchor` is non-nil at the top of history too, so a row offered on the
                // cursor alone would sit there forever re-requesting the first page.
                if model.feed.hasOlder {
                    loadOlderRow
                }
                ForEach(entries) { entry in
                    entryRow(entry)
                        .listRowInsets(Self.rowInsets)
                        // The card and the tinted user turn are what separate one entry from
                        // the next. A hairline through them as well draws a line across the
                        // middle of a rounded panel, which is the same defect that keeps the
                        // fleet list inset-grouped and this list plain.
                        .listRowSeparator(.hidden)
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
                DragGesture(minimumDistance: 1).onChanged { _ in lastReaderScroll = Date() }
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
                    open: model.blocked(agent: session?.agent, activity: session?.activity),
                    agent: session?.agent,
                    state: model.answerState,
                    model: model
                )
                PromptComposer(session: session, model: model)
            }
        }
        // The event trigger. `activity` and the title change live on the fleet socket, and a
        // change to either is the cheapest possible signal that this session has moved — most
        // importantly the busy → idle transition, which is the moment the last records of a
        // turn have landed.
        .onChange(of: session?.activity) { _, _ in model.loadNewer() }
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
        // **A retry, not a poll**, and it exists for one race. The status file and the
        // transcript are written by independent paths in claude, so a fetch fired the instant
        // `waiting` arrives can beat the record to disk — leaving a session the phone knows is
        // blocked with nothing in the feed to say on what. One deferred fetch closes it.
        //
        // Deliberately NOT a loop. A `waiting` session can sit for an hour, and a screen that
        // polled through it would spend a battery to re-read a file that changes when the
        // human moves. If the manual checklist finds this flaky, the fix is a SECOND retry at
        // a longer delay, not a `while`.
        //
        // A separate `.task(id:)` from the busy poll above rather than a branch inside it: two
        // modifiers with the same id both run, and merging them would tie two different
        // cadences — a 1.5s follow and a one-shot catch-up — to one decision.
        .task(id: session?.activity) {
            guard session?.activity == "waiting" else { return }
            try? await Task.sleep(for: .milliseconds(900))
            guard !Task.isCancelled else { return }
            model.loadNewer()
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
            toggleExpanded: { expansion.toggle(entry.id) }
        )
        if TimelineStyle.opensDetail(entry.item) {
            NavigationLink(value: entry.item) { row }
        } else {
            row
        }
    }

    /// A button, not an `onAppear` trigger. An automatic fetch on the top row appearing fires
    /// again on every bounce of an over-scroll and, worse, fires while the list is still
    /// settling after the previous page was inserted — so the reader is dragged upward by
    /// content arriving above them. An explicit tap costs one gesture and puts the reader in
    /// charge of where they are.
    private var loadOlderRow: some View {
        Button {
            model.loadOlder()
        } label: {
            HStack(spacing: 6) {
                Spacer()
                if model.isLoadingOlder {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.up").font(.caption2)
                    Text("Load earlier").font(.footnote.weight(.medium))
                }
                Spacer()
            }
            .padding(.vertical, 8)
            .background(
                Capsule().fill(Color(.secondarySystemBackground))
            )
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        // The label is stated rather than left to the content, because half the time the
        // content is a `ProgressView` — which announces nothing — and a reader on VoiceOver
        // would lose the only way up through the conversation for as long as a fetch runs.
        .accessibilityLabel("Load earlier")
        .listRowInsets(Self.rowInsets)
        .listRowSeparator(.hidden)
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
        case failed(String)
    }

    /// The notice that belongs above the conversation, or `nil` for none.
    ///
    /// **This is where a failure lands once there is content**, and the placement is the
    /// point. `SessionTimelineModel` only reaches `.failed` from a fetch the reader caused —
    /// a poll is quiet by design — so with content on screen the failure is almost always the
    /// "Load earlier" tap at the top, and the deadline makes that a *fifteen second* gap
    /// between the tap and the answer. Putting the reason at the bottom of a list the reader
    /// has scrolled to the top of is the same defect as a spinner that never ends: the
    /// spinner stops, and nothing they can see says why.
    ///
    /// Suppressed while `isLoadingOlder`, because `phase` keeps the last failure until a
    /// fetch succeeds: a retry would otherwise spin on the row directly under the stale
    /// explanation of the attempt before it.
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
        case .failed(let message):
            failureNotice(message)
        }
    }

    /// The reason, and — when the whole screen is the failure — a way to try again.
    ///
    /// With a conversation on screen there is deliberately **no** button here: the failure is
    /// almost always the "Load earlier" tap, and that button is the row directly below this
    /// one. A second control doing the same job one row apart is how a reader ends up
    /// re-issuing a fetch they cannot see the state of.
    private func failureNotice(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if model.feed.items.isEmpty {
                Button("Try again") { model.loadLatest() }
                    .font(.footnote.weight(.medium))
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
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

    /// The only live claim on the screen, and it is about the session rather than about the
    /// last row — see this type's own comment.
    enum Activity: Equatable {
        case working(String)
        case waiting(String)
    }

    /// What the session itself is doing, said the way the Mac says it.
    ///
    /// **`subagentSummary`, never `subagentCount`.** It is `nil` for codex at any count, and
    /// a codex tab's `0` means *unknown* rather than *none* — see that property, which is the
    /// one place this rule lives so the status glyph and this footer cannot disagree about
    /// the same session. Rendering "0 subagents" here would assert something nobody has
    /// grounds to say.
    ///
    /// The reason for `waiting` is dropped when it is EMPTY as well as when it is absent,
    /// matching `SessionStatusGlyph.label(for:)`: an agent that sent `""` would otherwise
    /// leave the row reading "Waiting for you — " with the sentence cut off after the dash.
    static func activityFooter(for session: WireSession?) -> Activity? {
        switch session?.activity {
        case "busy":
            guard let summary = session?.subagentSummary else { return .working("Working") }
            return .working("Working — \(summary)")
        case "waiting":
            guard let waitingFor = session?.waitingFor, !waitingFor.isEmpty else {
                return .waiting("Waiting for you")
            }
            return .waiting("Waiting for you — \(waitingFor)")
        default:
            // Including `nil` twice over — no agent process registered, and no session in the
            // fleet at all — and including an activity this build has never heard of. None of
            // them is something live to announce at the foot of a conversation.
            return nil
        }
    }

    /// Same symbol and same tint as the fleet list's glyph for the same two states, because
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
}
