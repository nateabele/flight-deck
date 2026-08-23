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

    var body: some View {
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
            ForEach(model.feed.items) { item in
                NavigationLink(value: item) {
                    TimelineRow(item: item)
                }
                .listRowInsets(Self.rowInsets)
            }
            if let notice = Self.bottomNotice(
                phase: model.phase, hasItems: !model.feed.items.isEmpty
            ) {
                noticeRow(notice)
            }
            if !model.feed.items.isEmpty, let activity = Self.activityFooter(for: session) {
                activityRow(activity)
            }
        }
        // `.plain` HERE, unlike the fleet list, and the reason is the content rather than
        // taste: this list is prose and command output in a monospaced face, and
        // inset-grouped's card edges cut every line short and put a rounded corner through
        // the middle of a diff. The fleet list's own comment explains why IT keeps
        // inset-grouped; the two screens differ because what they hold differs.
        .listStyle(.plain)
        .navigationTitle(session?.title ?? "Session")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(for: TimelineItem.self) { item in
            TimelineItemDetailScreen(
                item: item,
                result: Self.pairedResult(for: item, in: model.feed.items)
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
    }

    /// Matches the fleet list's row insets, so the two screens' left edges line up when one
    /// pushes the other.
    private static let rowInsets = EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16)

    /// A button, not an `onAppear` trigger. An automatic fetch on the top row appearing fires
    /// again on every bounce of an over-scroll and, worse, fires while the list is still
    /// settling after the previous page was inserted — so the reader is dragged upward by
    /// content arriving above them. An explicit tap costs one gesture and puts the reader in
    /// charge of where they are.
    private var loadOlderRow: some View {
        Button {
            model.loadOlder()
        } label: {
            HStack {
                Spacer()
                if model.isLoadingOlder {
                    ProgressView().controlSize(.small)
                } else {
                    Text("Load earlier").font(.footnote)
                }
                Spacer()
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        // The label is stated rather than left to the content, because half the time the
        // content is a `ProgressView` — which announces nothing — and a reader on VoiceOver
        // would lose the only way up through the conversation for as long as a fetch runs.
        .accessibilityLabel("Load earlier")
        .listRowInsets(Self.rowInsets)
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

    @ViewBuilder
    private func noticeRow(_ notice: Notice) -> some View {
        switch notice {
        case .loading:
            HStack {
                Spacer()
                ProgressView()
                Spacer()
            }
            .listRowInsets(Self.rowInsets)
        case .empty:
            Text("No messages yet.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .listRowInsets(Self.rowInsets)
        case .failed(let message):
            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .listRowInsets(Self.rowInsets)
        }
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
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text(text)
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .listRowInsets(Self.rowInsets)
        case .waiting(let text):
            Label(text, systemImage: "questionmark.circle.fill")
                .font(.footnote)
                .foregroundStyle(.orange)
                .listRowInsets(Self.rowInsets)
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
