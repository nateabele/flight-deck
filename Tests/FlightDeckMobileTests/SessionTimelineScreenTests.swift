import FleetKit
import XCTest
@testable import FlightDeckMobile

/// The three decisions the session screen makes that are not layout.
///
/// What a unit test in this process cannot reach is everything SwiftUI renders — where a row
/// lands, how a monospaced line wraps, whether `.listStyle(.plain)` did anything — and
/// docs/MOBILE.md's checklist owns that. What it *can* reach is which row exists at all,
/// which is where this screen's real failures live: a failure reported where nobody is
/// looking, an empty state that lies about a fetch still running, "0 subagents" for an agent
/// that never reports any, and a command captioned with a different command's output.
///
/// **Every fixture below keeps a record's id and its `callID` in different spaces on
/// purpose.** Item ids are byte offsets (`"1400#0"`) and call ids are the agent's own
/// (`"toolu_a1"`), which is exactly the distinction `TimelineItem.Body.callID` exists to
/// state — and a fixture that let one stand in for the other would pass against an
/// implementation that paired on the wrong one.
final class SessionTimelineScreenTests: XCTestCase {

    // MARK: When history is asked for

    /// **The trigger is not the top row, and the distance is the whole design.** An `onAppear`
    /// on the oldest row re-fires on every bounce of an over-scroll and lands its page while
    /// the list is still settling, dragging the reader upward — which is why this screen used
    /// to make them tap a button instead. A page below the top, the rubber-band never reaches
    /// it, and the read finishes before the reader does.
    func testTheReadOfMoreHistoryStartsAPageBeforeTheReaderReachesTheTop() {
        let entries = SessionTimelineScreen.entries(
            from: (0..<200).map { prose(at: $0 * 10) }
        )

        let trigger = SessionTimelineScreen.prefetchTrigger(entries)

        XCTAssertEqual(trigger, entries[SessionTimelineScreen.prefetchDepth].id)
        XCTAssertNotEqual(trigger, entries.first?.id,
                          "the oldest row is exactly what must NOT be the trigger")
    }

    /// **The clamp, and the sessions it exists for are the ones that need it most.** A feed
    /// holding less than a page has no entry at `prefetchDepth`, so an unclamped lookup
    /// answers `nil` — and a screen that loaded one short page would then never ask for a
    /// second, leaving the reader at the top of a conversation that has more behind it.
    func testAFeedShorterThanTheRunwayStillHasATriggerRatherThanNone() {
        let entries = SessionTimelineScreen.entries(from: (0..<3).map { prose(at: $0 * 10) })
        XCTAssertLessThan(entries.count, SessionTimelineScreen.prefetchDepth, "the premise")

        XCTAssertEqual(SessionTimelineScreen.prefetchTrigger(entries), entries.first?.id,
                       "the oldest row it has, because there is nothing deeper to use")
    }

    /// Nothing to trigger on, and nothing to crash on: an empty feed is the state every
    /// session is in for the first round trip of its life.
    func testAnEmptyConversationHasNothingToTriggerOn() {
        XCTAssertNil(SessionTimelineScreen.prefetchTrigger([]))
    }

    // MARK: Where a failure is said

    /// **The deadline case, and the reason placement is a decision rather than a detail.**
    /// A re-read of the live edge that goes unanswered — the fetch a reader causes by coming
    /// back to a kept screen — fails fifteen seconds later, by which time whatever was
    /// spinning has simply stopped. If the reason renders at the bottom of
    /// a list the reader has scrolled to the top of, the screen has reproduced the exact
    /// defect the deadline was added to prevent: something stopped, and nothing visible says
    /// why.
    func testAFailureWithAConversationOnScreenIsSaidAtTheTopWhereTheTapWasNotBelowTheFold() {
        let phase = SessionTimelineModel.Phase.failed("Your Mac didn't answer in time.")

        XCTAssertEqual(
            SessionTimelineScreen.topNotice(phase: phase, hasItems: true, isLoadingOlder: false),
            .failed("Your Mac didn't answer in time.")
        )
        XCTAssertNil(
            SessionTimelineScreen.bottomNotice(phase: phase, hasItems: true),
            "said twice is worse than said once in the wrong place"
        )
    }

    /// With nothing on screen there is no top and no bottom — the notice is the whole screen
    /// — and it must still appear exactly once.
    func testAFailureOnAnEmptyScreenIsSaidOnceAndIsNotAnEmptyState() {
        let phase = SessionTimelineModel.Phase.failed("Not connected to your Mac.")

        XCTAssertNil(
            SessionTimelineScreen.topNotice(phase: phase, hasItems: false, isLoadingOlder: false)
        )
        XCTAssertEqual(
            SessionTimelineScreen.bottomNotice(phase: phase, hasItems: false),
            .failed("Not connected to your Mac."),
            "a refusal that renders as 'No messages yet.' blames the conversation for the link"
        )
    }

    /// `phase` keeps the last failure until a fetch succeeds, so a reader who taps "Load
    /// earlier" again would otherwise get a spinner sitting directly under the explanation of
    /// the attempt before it — two rows describing two different moments as though they were
    /// one.
    func testARetryReplacesTheReasonTheLastAttemptFailedRatherThanSpinningBesideIt() {
        XCTAssertNil(SessionTimelineScreen.topNotice(
            phase: .failed("Your Mac didn't answer in time."),
            hasItems: true, isLoadingOlder: true
        ))
    }

    /// Three states, three screens. Collapsing "still loading" into "nothing here" is how an
    /// empty state ends up claiming a session has no history when the page simply has not
    /// landed yet.
    func testAnEmptyConversationSaysSoOnlyOnceTheFetchHasAnswered() {
        XCTAssertEqual(
            SessionTimelineScreen.bottomNotice(phase: .loading, hasItems: false), .loading
        )
        XCTAssertEqual(
            SessionTimelineScreen.bottomNotice(phase: .idle, hasItems: false), .empty
        )
    }

    /// The conversation is the last thing the Mac said and it stays on screen through
    /// everything: a page fetched above it does not replace it with a spinner, and an idle
    /// screen full of content does not append "No messages yet." under it.
    func testContentIsNeverFollowedByASpinnerOrByAnEmptyState() {
        XCTAssertNil(SessionTimelineScreen.topNotice(
            phase: .loading, hasItems: true, isLoadingOlder: false
        ))
        XCTAssertNil(SessionTimelineScreen.bottomNotice(phase: .loading, hasItems: true))
        XCTAssertNil(SessionTimelineScreen.bottomNotice(phase: .idle, hasItems: true))
    }

    // MARK: What the session is doing

    /// **`subagentCount` is 0 for codex at all times and 0 there means unknown**, which is
    /// why this goes through `subagentSummary` and why the second half of this test is not
    /// redundant: an implementation that read the count directly would say "0 subagents" for
    /// every codex session on the fleet, and one that special-cased only zero would start
    /// claiming counts the moment a future Mac put a number there for another reason.
    func testACodexSessionNeverClaimsANumberOfSubagents() {
        XCTAssertEqual(
            SessionTimelineScreen.activityFooter(
                for: session(agent: "codex", activity: "busy", subagentCount: 0)
            ),
            .working("Working")
        )
        XCTAssertEqual(
            SessionTimelineScreen.activityFooter(
                for: session(agent: "codex", activity: "busy", subagentCount: 3)
            ),
            .working("Working"),
            "nothing emits a sub-agent count for codex, so a count there is not ground truth"
        )
    }

    /// Claude has a real count, and it is singularized the way the Mac's own tooltip
    /// singularizes it — this footer and the list's status glyph describe the same session
    /// two taps apart.
    func testAClaudeSessionCountsItsSubagentsTheWayTheMacDoes() {
        XCTAssertEqual(
            SessionTimelineScreen.activityFooter(
                for: session(agent: "claude", activity: "busy", subagentCount: 1)
            ),
            .working("Working — 1 subagent")
        )
        XCTAssertEqual(
            SessionTimelineScreen.activityFooter(
                for: session(agent: "claude", activity: "busy", subagentCount: 3)
            ),
            .working("Working — 3 subagents")
        )
        XCTAssertEqual(
            SessionTimelineScreen.activityFooter(
                for: session(agent: "claude", activity: "busy", subagentCount: 0)
            ),
            .working("Working"),
            "a claude session between sub-agents is working, not working on nothing"
        )
    }

    /// The reason is dropped when it is empty as well as when it is absent. An agent that
    /// sends `""` — and `waitingFor` is verbatim from the agent — would otherwise leave the
    /// footer reading "Waiting for you — " with the sentence cut off after the dash.
    func testWaitingCarriesTheReasonAndAnEmptyReasonIsNotADanglingDash() {
        XCTAssertEqual(
            SessionTimelineScreen.activityFooter(
                for: session(activity: "waiting", waitingFor: "permission prompt")
            ),
            .waiting("Waiting for you — permission prompt")
        )
        XCTAssertEqual(
            SessionTimelineScreen.activityFooter(for: session(activity: "waiting")),
            .waiting("Waiting for you")
        )
        XCTAssertEqual(
            SessionTimelineScreen.activityFooter(
                for: session(activity: "waiting", waitingFor: "")
            ),
            .waiting("Waiting for you")
        )
    }

    /// The footer is the one live claim on the screen, so every state that is not live must
    /// make none. `nil` for the session covers the two ways it goes missing — closed on the
    /// Mac while the screen is open, and a fleet that has not arrived yet — and an activity
    /// this build has never heard of gets the same silence, for the reason `WireSession`
    /// carries `activity` as a `String` at all.
    func testASessionThatIsNotWorkingSaysNothingAtTheFootOfTheConversation() {
        XCTAssertNil(SessionTimelineScreen.activityFooter(for: session(activity: "idle")))
        XCTAssertNil(SessionTimelineScreen.activityFooter(for: session(activity: nil)))
        XCTAssertNil(SessionTimelineScreen.activityFooter(for: session(activity: "compacting")))
        XCTAssertNil(SessionTimelineScreen.activityFooter(for: nil))
    }

    /// The footer's text comes from `SessionStatusGlyph.label(for:)`, so the background
    /// clause reaches it automatically — the same string a reader saw on the fleet list row
    /// they tapped to get here, character for character.
    func testWorkingAndWaitingCarryTheBackgroundClauseTheSameWayTheFleetListDoes() {
        XCTAssertEqual(
            SessionTimelineScreen.activityFooter(
                for: session(activity: "busy", subagentCount: 2, hasBackgroundWork: true)
            ),
            .working("Working — 2 subagents — background command running")
        )
        XCTAssertEqual(
            SessionTimelineScreen.activityFooter(
                for: session(
                    activity: "waiting", waitingFor: "permission prompt",
                    hasBackgroundWork: true
                )
            ),
            .waiting("Waiting for you — permission prompt — background command running")
        )
    }

    /// The one case this footer used to have nothing to say about: a turn that finished
    /// (`idle`) with a background task still running underneath it. Showing a badge on the
    /// fleet list row and nothing here would tell a reader two different stories about the
    /// same session two taps apart — see `activityFooter`'s own comment.
    func testIdleWithBackgroundWorkGetsAFooterWherePlainIdleGetsNone() {
        XCTAssertEqual(
            SessionTimelineScreen.activityFooter(
                for: session(activity: "idle", hasBackgroundWork: true)
            ),
            .background("Idle — background command running")
        )
        XCTAssertNil(
            SessionTimelineScreen.activityFooter(
                for: session(activity: "idle", hasBackgroundWork: false)
            )
        )
    }

    // MARK: One row per thing that happened

    /// **A command and its output are one thing, and the feed carries them as two records.**
    /// Rendered as sibling rows they read as two unrelated events — a marker glyph did not
    /// join them across a row separator, which the renders showed plainly — so the result is
    /// folded into the call's own row. On `callID`, never on position: the fixture below has
    /// two tools in flight answered in the opposite order to the calls, so an implementation
    /// that took the next result gets both of them wrong rather than one right by luck.
    func testAToolResultIsFoldedIntoItsOwnCallAndNotTheOneBeforeIt() {
        let entries = SessionTimelineScreen.entries(from: interleavedCalls())

        XCTAssertEqual(entries.map(\.id), ["1000#0", "1200#0"], "two calls, two rows")
        // Subscripting `entries` is subscripting the OUTPUT of the code under test, so a
        // count assertion has to gate it. Without this, a fold regression fails the line
        // above and then TRAPS on the line below — which kills the whole xctest process
        // and takes every later test with it, reported to the user as the app quitting.
        // Seen for real: two mutation runs surfaced as "FlightDeckMobile quit unexpectedly".
        guard entries.count == 2 else { return XCTFail("expected two rows, got \(entries.count)") }
        XCTAssertEqual(entries[0].result?.id, "1600#0", "toolu_a1's output, wherever it landed")
        XCTAssertEqual(entries[1].result?.id, "1400#0")
    }

    /// **A page boundary is enough to separate a result from its call**, and a result folded
    /// away when its call is not on screen is content deleted from the conversation — the one
    /// thing worse than showing it twice. So the set of calls actually present is what decides,
    /// not merely the result having an id.
    func testAResultWhoseCallIsNotOnScreenKeepsARowOfItsOwn() {
        let orphan = toolResult(id: "1400#0", callID: "toolu_a1")

        let entries = SessionTimelineScreen.entries(from: [orphan])

        XCTAssertEqual(entries.map(\.id), ["1400#0"], "nothing here answers a call nobody made")
        // Subscripting `entries` is subscripting the OUTPUT of the code under test, so a
        // count assertion has to gate it. Without this, a fold regression fails the line
        // above and then TRAPS on the line below — which kills the whole xctest process
        // and takes every later test with it, reported to the user as the app quitting.
        // Seen for real: two mutation runs surfaced as "FlightDeckMobile quit unexpectedly".
        guard entries.count == 1 else { return XCTFail("expected one row, got \(entries.count)") }
        XCTAssertNil(entries[0].result, "and it is not its own output")
    }

    /// Codex's `event_msg` records carry no call id at all. Two records that both have *none*
    /// are not two halves of one call, and folding on that basis would swallow every anonymous
    /// result into the first anonymous call in the conversation.
    func testTwoRecordsThatBothLackAnIDAreNotFoldedTogether() {
        let entries = SessionTimelineScreen.entries(from: [
            toolCall(id: "1000#0", callID: nil),
            toolResult(id: "1400#0", callID: nil),
        ])

        XCTAssertEqual(entries.map(\.id), ["1000#0", "1400#0"])
        // Subscripting `entries` is subscripting the OUTPUT of the code under test, so a
        // count assertion has to gate it. Without this, a fold regression fails the line
        // above and then TRAPS on the line below — which kills the whole xctest process
        // and takes every later test with it, reported to the user as the app quitting.
        // Seen for real: two mutation runs surfaced as "FlightDeckMobile quit unexpectedly".
        guard entries.count == 2 else { return XCTFail("expected two rows, got \(entries.count)") }
        XCTAssertNil(entries[0].result)
    }

    /// Everything that is not a tool record passes through untouched, in order. Folding is the
    /// one transformation this list does, and a prose row lost to it is a message that
    /// vanished.
    func testProseIsNeverFoldedAwayAndKeepsItsOrder() {
        let items = [
            TimelineFixtures.userTurn, TimelineFixtures.bashCall,
            TimelineFixtures.bashResult, TimelineFixtures.assistantAnswer,
            TimelineFixtures.thinking, TimelineFixtures.unknown,
        ]

        XCTAssertEqual(
            SessionTimelineScreen.entries(from: items).map(\.id),
            [
                TimelineFixtures.userTurn.id, TimelineFixtures.bashCall.id,
                TimelineFixtures.assistantAnswer.id, TimelineFixtures.thinking.id,
                TimelineFixtures.unknown.id,
            ]
        )
    }

    // MARK: Following a live session

    /// **A `List` draws oldest-first**, so the `.latest` page's newest record is off the bottom
    /// of the screen when it arrives. Without this the screen opens on the OLDEST message of
    /// the most recent page — which is what shipped, and is not "opens on the most recent
    /// messages" by any reading.
    ///
    /// It holds whether or not the reader is at the bottom, because on the first page there is
    /// no reader position to respect yet.
    func testTheFirstPageIsFollowedBecauseAListDrawsTheNewestRowOffTheBottom() {
        XCTAssertEqual(
            SessionTimelineScreen.follow(
                newest: "16410#0", lastFollowed: nil, readerIsAtBottom: false
            ),
            "16410#0"
        )
    }

    /// **The 1.5s poll runs the whole time a turn does**, so this is the rule that decides
    /// whether reading a finished turn is possible while the next one runs. A reader who has
    /// scrolled up is left exactly where they are.
    func testAReaderWhoScrolledUpIntoTheHistoryIsNotDraggedBackDownByAPoll() {
        XCTAssertNil(
            SessionTimelineScreen.follow(
                newest: "16880#0", lastFollowed: "16410#0", readerIsAtBottom: false
            )
        )
        XCTAssertEqual(
            SessionTimelineScreen.follow(
                newest: "16880#0", lastFollowed: "16410#0", readerIsAtBottom: true
            ),
            "16880#0",
            "a reader at the live edge came to watch it move"
        )
    }

    /// A poll that answers with nothing new must move nothing. `SessionTimelineModel` polls
    /// every 1.5s while a session is busy, and most of those answers add no records at all —
    /// a list that re-scrolled on each one would fight the reader's finger continuously.
    func testAPageWithNothingNewInItScrollsNothing() {
        XCTAssertNil(
            SessionTimelineScreen.follow(
                newest: "16410#0", lastFollowed: "16410#0", readerIsAtBottom: true
            )
        )
        XCTAssertNil(
            SessionTimelineScreen.follow(newest: nil, lastFollowed: nil, readerIsAtBottom: true),
            "an empty feed has no newest row to go to"
        )
    }

    // MARK: Pairing a call with its output

    /// **A session running two tools at once interleaves their records**, so "the first
    /// result in the feed" is a different call's output roughly half the time — and a caption
    /// under the wrong command is worse than no caption at all. `callID` is the agent's own
    /// id and the only thing that pairs these; `id` is a byte offset and pairs nothing.
    func testAToolCallIsPairedByCallIDAndNotByPositionOrByOffset() {
        let items = interleavedCalls()

        XCTAssertEqual(
            SessionTimelineScreen.pairedResult(for: items[0], in: items)?.id, "1600#0",
            "call toolu_a1's output is the one carrying toolu_a1, wherever it landed"
        )
        XCTAssertEqual(
            SessionTimelineScreen.pairedResult(for: items[1], in: items)?.id, "1400#0"
        )
    }

    /// The tool is still running, or its result fell the other side of a page boundary.
    /// Either way the honest answer is nothing, not the nearest result to hand.
    func testACallWhoseResultIsNotHeldIsPairedWithNothingRatherThanAStranger() {
        let items = [
            toolCall(id: "1000#0", callID: "toolu_a1"),
            toolResult(id: "1400#0", callID: "toolu_b2"),
        ]

        XCTAssertNil(SessionTimelineScreen.pairedResult(for: items[0], in: items))
    }

    /// A result row opens its own detail screen too, and it must not be handed itself as its
    /// own output — its `callID` matches its own, so the kind guard is the only thing between
    /// that row and showing the same text twice.
    func testAResultRowIsPairedWithNothingSoItCannotCaptionItself() {
        let items = interleavedCalls()

        XCTAssertNil(SessionTimelineScreen.pairedResult(for: items[2], in: items))
        XCTAssertNil(SessionTimelineScreen.pairedResult(for: items[3], in: items))
    }

    /// Codex's `event_msg` records carry no call id at all, and neither does anything a
    /// future mapper fails to find one in. Two records that both have *no* id are not two
    /// halves of one call, and matching them on that basis pairs every such call with the
    /// first anonymous result in the conversation.
    func testACallWithNoIdIsPairedWithNothingRatherThanWithAnotherRecordThatAlsoHasNone() {
        let items = [
            toolCall(id: "1000#0", callID: nil),
            toolResult(id: "1400#0", callID: nil),
        ]

        XCTAssertNil(SessionTimelineScreen.pairedResult(for: items[0], in: items))
    }

    // MARK: The plan gate

    /// The happy path: the gate names a call, that call is `ExitPlanMode`, and its own input
    /// carries the plan text the gate itself does not (see `WirePlanGate.plan`'s own comment).
    func testTranscriptPlanReadsExitPlanModesOwnInput() {
        let gate = WirePlanGate(callID: "toolu_plan1", tier: "verdict", plan: nil,
                                startedAt: "t", annotationCount: 0)
        let items = [exitPlanModeCall(id: "2000#0", callID: "toolu_plan1", plan: "# Title\n\nDo it.")]

        XCTAssertEqual(
            SessionTimelineScreen.transcriptPlan(for: gate, in: items), "# Title\n\nDo it."
        )
    }

    /// The call the gate names has not reached this feed's window — a page boundary, or a
    /// gate opened before the phone's earliest loaded page. `nil`, never another call's plan.
    func testTranscriptPlanIsNilWhenTheNamedCallIsNotHeld() {
        let gate = WirePlanGate(callID: "toolu_missing", tier: "verdict", plan: nil,
                                startedAt: "t", annotationCount: 0)
        let items = [exitPlanModeCall(id: "2000#0", callID: "toolu_plan1", plan: "A.")]

        XCTAssertNil(SessionTimelineScreen.transcriptPlan(for: gate, in: items))
    }

    /// A call id is only unique per agent turn, not globally — a `Bash` call that happens to
    /// share the gate's `callID` must not be mistaken for the plan call. `ExitPlanMode` is the
    /// other half of the match.
    func testTranscriptPlanIgnoresACallWithTheSameIdButTheWrongTool() {
        let gate = WirePlanGate(callID: "toolu_shared", tier: "verdict", plan: nil,
                                startedAt: "t", annotationCount: 0)
        let items = [toolCall(id: "2000#0", callID: "toolu_shared")]

        XCTAssertNil(SessionTimelineScreen.transcriptPlan(for: gate, in: items))
    }

    /// The Mac cuts an oversized tool call at its byte cap wherever that lands, so the JSON
    /// can be structurally incomplete by design (see `TimelineItem.Body.text`'s own comment).
    /// A body that fails to parse falls back to `nil`, not a crash.
    func testTranscriptPlanIsNilWhenTheBodyDoesNotParse() {
        let gate = WirePlanGate(callID: "toolu_plan1", tier: "verdict", plan: nil,
                                startedAt: "t", annotationCount: 0)
        let items = [
            TimelineItem(
                id: "2000#0", kind: .toolCall, status: .complete,
                body: TimelineItem.Body(
                    text: "{\"plan\": \"truncat", tool: "ExitPlanMode", callID: "toolu_plan1"
                )
            ),
        ]

        XCTAssertNil(SessionTimelineScreen.transcriptPlan(for: gate, in: items))
    }

    /// The banner's subtitle, read off the gate's own `startedAt`. Both timestamps are
    /// hours (or days) in the past rather than minutes, so a slow test run cannot tip the
    /// answer over a unit boundary between building the fixture and asserting on it.
    func testElapsedTextReadsAFractionalTimestamp() {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let startedAt = formatter.string(from: Date().addingTimeInterval(-7200))

        XCTAssertEqual(SessionTimelineScreen.elapsedText(since: startedAt), "Started 2 hours ago")
    }

    /// The fallback formatter, for a timestamp with no fractional seconds at all.
    func testElapsedTextFallsBackToAWholeSecondTimestamp() {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let startedAt = formatter.string(from: Date().addingTimeInterval(-172_800))

        XCTAssertEqual(SessionTimelineScreen.elapsedText(since: startedAt), "Started 2 days ago")
    }

    /// Neither formatter can parse it — the banner still draws its headline with no subtitle
    /// under it, rather than a crash.
    func testElapsedTextIsNilForSomethingThatIsNotATimestampAtAll() {
        XCTAssertNil(SessionTimelineScreen.elapsedText(since: "not-a-date"))
    }

    /// Two calls in flight, each answered after the other one was issued, with the results
    /// arriving in the opposite order to the calls. `items[0]`'s output is the LAST row and
    /// `items[1]`'s is the first result in the list, so an implementation that took position
    /// for pairing gets both of them wrong rather than one of them right by luck.
    private func interleavedCalls() -> [TimelineItem] {
        [
            toolCall(id: "1000#0", callID: "toolu_a1"),
            toolCall(id: "1200#0", callID: "toolu_b2"),
            toolResult(id: "1400#0", callID: "toolu_b2"),
            toolResult(id: "1600#0", callID: "toolu_a1"),
        ]
    }

    /// A plain assistant turn at a given byte offset. Prose rather than a call, so
    /// `entries(from:)` folds nothing and the entry count matches the item count — which is
    /// what makes an assertion about the trigger's *depth* mean what it says.
    private func prose(at offset: Int) -> TimelineItem {
        TimelineItem(
            id: "\(offset)#0", kind: .assistantText, status: .complete,
            body: TimelineItem.Body(text: "turn at \(offset)")
        )
    }

    private func toolCall(id: String, callID: String?) -> TimelineItem {
        TimelineItem(
            id: id, kind: .toolCall, status: .complete,
            body: TimelineItem.Body(
                text: "{\n  \"command\": \"git status\"\n}", summary: "git status",
                tool: "Bash", callID: callID
            )
        )
    }

    private func toolResult(id: String, callID: String?) -> TimelineItem {
        TimelineItem(
            id: id, kind: .toolResult, status: .complete,
            body: TimelineItem.Body(text: "nothing to commit", tool: "Bash", callID: callID)
        )
    }

    /// An `ExitPlanMode` call whose own input carries the plan text — the shape
    /// `transcriptPlan(for:in:)` reads for the `verdict` tier, where the gate itself has none.
    private func exitPlanModeCall(id: String, callID: String, plan: String) -> TimelineItem {
        let escaped = plan
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        return TimelineItem(
            id: id, kind: .toolCall, status: .complete,
            body: TimelineItem.Body(
                text: "{\"plan\": \"\(escaped)\"}", tool: "ExitPlanMode", callID: callID
            )
        )
    }

    private func session(
        agent: String = "claude", activity: String?, waitingFor: String? = nil,
        subagentCount: Int = 0, hasBackgroundWork: Bool = false
    ) -> WireSession {
        WireSession(
            id: UUID(), title: "flight-deck", agent: agent,
            activity: activity, waitingFor: waitingFor, subagentCount: subagentCount,
            hasBackgroundWork: hasBackgroundWork
        )
    }
}
