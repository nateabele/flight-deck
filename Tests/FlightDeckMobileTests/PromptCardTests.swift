import FleetKit
import XCTest
@testable import FlightDeckMobile

/// The card's decisions, extracted from the view so they can be asserted without a render —
/// the same shape `PromptComposerTests` uses, and for the same reason.
@MainActor
final class PromptCardTests: XCTestCase {
    private func question(unanswerable: String? = nil) -> OpenPrompt {
        .question(callID: "toolu_A", [PromptQuestion(
            header: "Pick", question: "Which?",
            options: [.init(label: "Yes"), .init(label: "No")], unanswerable: unanswerable
        )])
    }

    private let permission = OpenPrompt.permission(
        callID: "toolu_B", tool: "Bash", summary: "rm -rf build"
    )

    /// **Controls in exactly one state.** `sent` must not offer them — tapping twice answers
    /// twice — and `failed` must not either, because a Return may already be on its way.
    func testControlsAreOfferedOnlyBeforeAnAnswerIsSent() {
        XCTAssertTrue(PromptCard.showsControls(for: question(), state: .idle))
        XCTAssertFalse(PromptCard.showsControls(for: question(), state: .sent(call: "toolu_A")))
        XCTAssertFalse(
            PromptCard.showsControls(for: question(), state: .failed(call: "toolu_A", "nope"))
        )
    }

    /// A state left over from a PREVIOUS dialog must not suppress this one's controls — the
    /// harder race, seen from the phone: the session never left `waiting`, so the card was
    /// never torn down, and a failure filed against `toolu_ONE` would silently disable the
    /// buttons for `toolu_TWO`. Keyed on the call for exactly that reason.
    func testAStateFromADifferentCallDoesNotSuppressThisOnesControls() {
        XCTAssertTrue(
            PromptCard.showsControls(for: question(), state: .sent(call: "toolu_OTHER"))
        )
        XCTAssertTrue(
            PromptCard.showsControls(for: question(), state: .failed(call: "toolu_OTHER", "no"))
        )
    }

    /// And it must not put the previous dialog's footnote under this one's question either: a
    /// card reading "Sent to your Mac." over a question nobody has answered is a reader told
    /// their tap landed on something they never saw.
    func testAFootnoteFromADifferentCallIsNotShownUnderThisOne() {
        XCTAssertNil(PromptCard.footnote(for: question(), state: .sent(call: "toolu_OTHER")))
        XCTAssertNil(
            PromptCard.footnote(for: question(), state: .failed(call: "toolu_OTHER", "Moved on."))
        )
    }

    func testAnUnanswerableQuestionShowsItsReasonAndNoControls() {
        let multi = question(unanswerable: PromptQuestion.multiSelectReason)
        XCTAssertFalse(PromptCard.showsControls(for: multi, state: .idle))
        XCTAssertEqual(
            PromptCard.footnote(for: multi, state: .idle), PromptQuestion.multiSelectReason
        )
    }

    /// A permission card always has controls, because Allow and Deny do not come from a payload
    /// — they are the two intents `PromptAnswer` names. There is nothing to be unanswerable
    /// about.
    func testAPermissionCardAlwaysHasControls() {
        XCTAssertTrue(PromptCard.showsControls(for: permission, state: .idle))
        XCTAssertNil(PromptCard.footnote(for: permission, state: .idle))
    }

    func testASentAnswerSaysSoRatherThanSayingNothing() {
        XCTAssertEqual(
            PromptCard.footnote(for: question(), state: .sent(call: "toolu_A")),
            PromptCard.sentFootnote
        )
    }

    func testAFailureShowsTheMacsOwnReason() {
        XCTAssertEqual(
            PromptCard.footnote(for: question(), state: .failed(call: "toolu_A", "Moved on.")),
            "Moved on."
        )
    }

    /// A permission card names the tool and shows its command, which is more than the terminal
    /// shows — and it is all the phone has, because the dialog's own wording exists nowhere it
    /// can read.
    func testAPermissionCardIsTitledFromTheToolAndItsSummary() {
        XCTAssertEqual(
            PromptCard.title(for: permission, agent: "claude"), "Claude wants to run Bash"
        )
        XCTAssertEqual(PromptCard.subtitle(for: permission), "rm -rf build")
    }

    func testAPermissionCardForAToolWithNoSummaryStillHasATitle() {
        XCTAssertEqual(
            PromptCard.title(
                for: .permission(callID: "x", tool: nil, summary: nil), agent: "claude"
            ),
            "Claude is waiting for you"
        )
        XCTAssertNil(PromptCard.subtitle(for: .permission(callID: "x", tool: nil, summary: nil)))
    }

    /// **The name comes off the wire, and it used to be a literal.** A card that says
    /// "Claude" over another agent's session is a lie about whose terminal is blocked, and
    /// the only reason it is not on screen today is `OpenPrompt.find`'s gate — a second
    /// mechanism, in another module. If that gate is ever widened for an agent that becomes
    /// answerable, this is what keeps the sentence true.
    func testAPermissionCardNamesTheAgentTheFleetReported() {
        XCTAssertEqual(
            PromptCard.title(for: permission, agent: "codex"), "Codex wants to run Bash"
        )
        XCTAssertEqual(
            PromptCard.title(for: .permission(callID: "x", tool: nil, summary: nil),
                             agent: "codex"),
            "Codex is waiting for you"
        )
    }

    /// An agent the fleet did not name — or one a newer Mac added after this build shipped —
    /// gets the sentence with nobody's name in it rather than an invented one. The same rule
    /// `WireSession.subagentSummary` states for a count it has no grounds to assert: silence
    /// beats a guess, and `TimelineStyle.agentName` is the one table that decides it.
    func testAnUnnamedAgentIsNotGivenAName() {
        for agent in [nil, ""] as [String?] {
            XCTAssertEqual(
                PromptCard.title(for: permission, agent: agent), "Waiting to run Bash",
                "agent \(String(describing: agent))"
            )
            XCTAssertEqual(
                PromptCard.title(for: .permission(callID: "x", tool: nil, summary: nil),
                                 agent: agent),
                "Waiting for you",
                "agent \(String(describing: agent))"
            )
        }
    }

    /// A question's own words are its title, and it has no second line: an option's meaning
    /// lives in that option's description, not above the list.
    func testAQuestionIsTitledWithTheQuestionAndHasNoSubtitle() {
        XCTAssertEqual(PromptCard.title(for: question(), agent: "claude"), "Which?")
        XCTAssertNil(PromptCard.subtitle(for: question()))
    }

    /// A historical row rebuilds its question with the same parser the live card uses. A body
    /// the parser refuses — a truncated one — falls back to the raw text rather than nothing.
    func testAHistoricalRowRebuildsItsQuestionFromTheBody() throws {
        let body = #"{"questions":[{"question":"Which?","options":[{"label":"a"}]}]}"#
        XCTAssertEqual(try XCTUnwrap(PromptQuestion(toolInput: body)).question, "Which?")
        XCTAssertNil(PromptQuestion(toolInput: String(body.prefix(20))))
    }

    // MARK: A call that asks several questions

    private func twoQuestions(multiSelectFirst: Bool = false) -> OpenPrompt {
        .question(callID: "toolu_SET", [
            PromptQuestion(header: "Language", question: "Which language?",
                           options: [.init(label: "Rust"), .init(label: "Go")],
                           unanswerable: multiSelectFirst
                               ? PromptQuestion.multiSelectReason : nil),
            PromptQuestion(header: "Editor", question: "Which editor?",
                           options: [.init(label: "Vim"), .init(label: "Emacs")]),
        ])
    }

    /// **The title stops being question one's words.** A set of two used to render as its first
    /// question, read-only, with the other one nowhere on screen — so a reader could not see
    /// what they were being sent to their Mac to answer, or even how much of it there was.
    func testASetOfQuestionsIsTitledByItsCountRatherThanByItsFirstQuestion() {
        let title = PromptCard.title(for: twoQuestions(), agent: "claude")
        XCTAssertEqual(title, "2 questions")
        XCTAssertNotEqual(title, "Which language?", "question one is not the whole prompt")
    }

    /// A single question is untouched by any of this.
    func testASingleQuestionStillTitlesItselfWithItsOwnWords() {
        XCTAssertEqual(PromptCard.title(for: question(), agent: "claude"), "Which?")
    }

    /// **A set is answerable now, and this is the assertion that flipped.** It used to read
    /// "read-only until something can drive one"; `AnswerPlan` and `SessionStore`'s set path
    /// are that something. The card collects a choice per question and sends them together.
    func testASetIsAnswerableAndSaysNothingAboutGoingToTheMac() {
        XCTAssertTrue(PromptCard.showsControls(for: twoQuestions(), state: .idle))
        XCTAssertNil(PromptCard.footnote(for: twoQuestions(), state: .idle),
                     "there is no longer anything to apologise for")
    }

    /// A question that takes several answers is a shape the driver handles, not a refusal, so
    /// a set containing one is still answerable.
    func testASetContainingACheckboxQuestionIsStillAnswerable() {
        let mixed = OpenPrompt.question(callID: "toolu_SET", [
            PromptQuestion(header: "Snacks", question: "Which snacks?",
                           options: [.init(label: "Pretzels"), .init(label: "Cookies")],
                           multiSelect: true),
            PromptQuestion(header: "Seat", question: "Which seat?",
                           options: [.init(label: "Window"), .init(label: "Aisle")]),
        ])
        XCTAssertTrue(PromptCard.showsControls(for: mixed, state: .idle))
        XCTAssertNil(PromptCard.footnote(for: mixed, state: .idle))
    }

    /// A genuine refusal still surfaces. `unanswerable` now means only what it says — a shape
    /// this Mac cannot drive — and one anywhere in a set stops the whole set, because the Mac
    /// commits it as a unit.
    func testARealRefusalAnywhereInASetStopsTheWholeSet() {
        let blocked = OpenPrompt.question(callID: "toolu_SET", [
            PromptQuestion(question: "Fine?", options: [.init(label: "Yes")]),
            PromptQuestion(question: "Odd?", options: [.init(label: "Yes")],
                           unanswerable: "Flight Deck can't answer this one from here."),
        ])
        XCTAssertFalse(PromptCard.showsControls(for: blocked, state: .idle))
        XCTAssertEqual(PromptCard.footnote(for: blocked, state: .idle),
                       "Flight Deck can't answer this one from here.")
    }

    // MARK: - Blocked: the dialog nothing on this build can read

    /// **Every input is required — see `showsBlocked`'s own comment for why no subset of them
    /// is enough.** `exhausted` alone would draw Blocked over a card that is
    /// simply present (row 2). `allowsAbort` alone would draw it before the chase has even
    /// finished (implied by row 1, where nothing has exhausted yet). And dropping `hasCard`
    /// would draw it whether or not a Mac too old to honour the abort ever gets asked (row 3).
    /// Only the last row — everything lined up — is Blocked.
    func testBlockedAppearsOnlyAfterTheChaseGivesUpAndOnlyWhenAllowed() {
        XCTAssertFalse(PromptCard.showsBlocked(
            exhausted: false, allowsAbort: true, hasCard: false,
            activity: "waiting", call: .noPrompt))
        XCTAssertFalse(PromptCard.showsBlocked(
            exhausted: true, allowsAbort: true, hasCard: true,
            activity: "waiting", call: .noPrompt))
        XCTAssertFalse(PromptCard.showsBlocked(
            exhausted: true, allowsAbort: false, hasCard: false,
            activity: "waiting", call: .noPrompt))
        XCTAssertTrue(PromptCard.showsBlocked(
            exhausted: true, allowsAbort: true, hasCard: false,
            activity: "waiting", call: .noPrompt))
    }

    /// **The latch outlives the episode, and this is what stops it drawing a card.**
    /// `blockedChaseExhausted` is cleared only from inside `chaseBlockedPrompt`, and the
    /// screen's chase task returns *before* entering it once the session stops being
    /// `waiting` — so a stuck episode that resolves at the keyboard leaves the flag `true`,
    /// `blocked(...)` returning nil (`OpenPrompt.find` gates on `waiting`), and every
    /// phone-side input to this predicate pointing at Blocked. Without the activity test the
    /// card would sit on a busy or idle session forever, offering a destructive Abort the Mac
    /// refuses `not_waiting` — silently, because `abortBlockedPrompt` discards its completion.
    func testBlockedIsWithdrawnOnceTheSessionIsNoLongerWaiting() {
        for activity in ["busy", "idle", nil] {
            XCTAssertFalse(
                PromptCard.showsBlocked(
                    exhausted: true, allowsAbort: true, hasCard: false,
                    activity: activity, call: .noPrompt),
                "a latched exhaustion must not outlive the episode it was latched during " +
                "(activity=\(activity ?? "nil"))")
        }
    }

    /// **The Mac naming the dialog is the phone's problem, not the Mac's.** A body this build
    /// cannot parse or a page that never landed exhausts the chase while the Mac's
    /// `openPromptCall` names the call fine. Drawing Blocked there tells the reader *"This Mac
    /// can't read the dialog on screen"* — false — and puts a blind Escape under it aimed at a
    /// real tool call they were never shown. Only `.noPrompt`, the Mac agreeing it can name
    /// nothing, earns the card.
    func testBlockedIsNotDrawnOverADialogTheMacCanName() {
        XCTAssertFalse(
            PromptCard.showsBlocked(
                exhausted: true, allowsAbort: true, hasCard: false,
                activity: "waiting", call: .call("toolu_REAL")),
            "a call the Mac names is a card this phone failed to build, not an unreadable " +
            "dialog — Abort here would deny a tool call nobody was shown")
        XCTAssertFalse(
            PromptCard.showsBlocked(
                exhausted: true, allowsAbort: true, hasCard: false,
                activity: "waiting", call: .unreported),
            "a Mac too old to report the field has said nothing about this dialog either way")
    }
}

extension FleetModel {
    /// A `FleetModel` with nowhere to persist a pairing and no connector to reach — `sendPrompt`
    /// therefore completes synchronously with `.disconnected`, which is exactly what
    /// `abortBlockedPrompt` needs: nothing here asserts the send arrives anywhere, only that it
    /// is sent, and sent once per token. `InMemoryPairedMacStore` is FleetKit's own "for tests
    /// and previews" store — this file has no reason to reach for `FleetModelTests`' private
    /// `RefusingPairedMacStore`, which exists to make `save` fail, not to stand in for a real one.
    static func fixture() -> FleetModel {
        FleetModel(store: InMemoryPairedMacStore())
    }
}

/// `FleetModel.abortBlockedPrompt(session:)`'s token dedup, asserted directly against the model
/// that mints and caches the token — see `PromptCard.swift`'s own comment on why this button's
/// action is a plain closure rather than a fourth `SessionTimelineModel.fleet` protocol: there is
/// no local state transition here for a stub's seam to exist for, so there is nothing for
/// `SessionTimelineModelTests`-style fakes to add. This lives beside `PromptCardTests` rather
/// than in `FleetModelTests` because it is this task's own escape hatch, not a general
/// `FleetModel` behaviour.
@MainActor
final class FleetModelBlockedAbortTests: XCTestCase {
    /// **Two taps, one command.** The button gives no feedback of its own — nothing tears the
    /// Blocked card down until the Mac's status moves on — so a second tap is the ordinary
    /// response to the first appearing to do nothing. Sent with the same token twice, the Mac's
    /// `answeredPromptTokens` collapses the replay to `.duplicate` rather than pressing Escape
    /// twice; this asserts the phone's half of that: the token, and therefore the intent, does
    /// not change between taps.
    func testAbortSendsOneTokenReusedOnASecondTap() async {
        let model = FleetModel.fixture()
        let id = UUID()

        await model.abortBlockedPrompt(session: id)
        await model.abortBlockedPrompt(session: id)

        let tokens: [UUID] = model.sentCommands.compactMap {
            if case .abortPrompt(let sentID, let token) = $0, sentID == id { return token }
            return nil
        }
        XCTAssertEqual(tokens.count, 2, "both taps must still reach sendPrompt")
        XCTAssertEqual(tokens.first, tokens.last, "reused, not re-minted, on the second tap")
    }

    /// A different session gets its own token — the cache is keyed per session, not global, so
    /// one blocked tab's abort can never dedup another's.
    func testAbortTokensAreScopedPerSession() async {
        let model = FleetModel.fixture()
        let first = UUID()
        let second = UUID()

        await model.abortBlockedPrompt(session: first)
        await model.abortBlockedPrompt(session: second)

        let tokens: [UUID: UUID] = model.sentCommands.reduce(into: [:]) { result, command in
            if case .abortPrompt(let sentID, let token) = command { result[sentID] = token }
        }
        XCTAssertNotEqual(tokens[first], tokens[second])
    }

    /// **A genuinely new episode mints a genuinely new token.** Without `noteSessionActivity`
    /// clearing the cache when a session leaves `waiting`, this session's second blocked dialog
    /// would replay the first episode's token — which the Mac's `answeredPromptTokens` already
    /// marked spent, so it would collapse to `.duplicate` *before* typing Escape, and Abort
    /// would silently do nothing for the rest of the pairing. That is the failure this test
    /// exists to catch; see `FleetModel.abortBlockedPrompt(session:)`'s own comment for the full
    /// chain. This is deliberately a different assertion from
    /// `testAbortSendsOneTokenReusedOnASecondTap` above, not its opposite: that test's two taps
    /// both land on one still-open dialog, while these two calls are separated by the session
    /// resolving and blocking again — the episode boundary is the whole point.
    func testAGenuineSecondBlockedEpisodeMintsAFreshToken() async {
        let model = FleetModel.fixture()
        let id = UUID()

        model.noteSessionActivity(id, waiting: true)
        await model.abortBlockedPrompt(session: id)

        model.noteSessionActivity(id, waiting: false)
        model.noteSessionActivity(id, waiting: true)
        await model.abortBlockedPrompt(session: id)

        let tokens: [UUID] = model.sentCommands.compactMap {
            if case .abortPrompt(let sentID, let token) = $0, sentID == id { return token }
            return nil
        }
        XCTAssertEqual(tokens.count, 2, "both episodes must still reach sendPrompt")
        XCTAssertNotEqual(
            tokens.first, tokens.last,
            "a resolved episode's token must not be replayed into a later one"
        )
    }

    /// `testAGenuineSecondBlockedEpisodeMintsAFreshToken` above pins `noteSessionActivity`
    /// directly, which leaves two things it cannot catch: the `for session in
    /// fleet.projects.flatMap(\.sessions)` loop inside `connector.onFleet` that calls it, and
    /// the `session.activity == "waiting"` string this maps from. Delete the loop, or change
    /// the string, and that test still passes. This one drives `noteFleet(_:)` — the method the
    /// loop was extracted into — with constructed `FleetSnapshot` values instead, so both are
    /// exercised: a snapshot naming the session `"waiting"` twice must still share one token
    /// (the loop runs and the string matches, so nothing is cleared in between), and a snapshot
    /// naming it anything else must drop the token before the next `"waiting"` one mints a new
    /// one. No `FleetConnector` needed — `noteFleet` takes the same `FleetSnapshot` its closure
    /// would have handed it.
    func testNoteFleetTracksWaitingAcrossSnapshotsForBothTheLoopAndTheString() async {
        let model = FleetModel.fixture()
        let id = UUID()
        let projectID = UUID()

        func snapshot(activity: String?) -> FleetSnapshot {
            FleetSnapshot(projects: [
                WireProject(
                    id: projectID, name: "P", path: "/p",
                    sessions: [WireSession(id: id, title: "T", agent: "claude", activity: activity)]
                )
            ])
        }

        // Still waiting across two snapshots — same episode, must keep one token.
        model.noteFleet(snapshot(activity: "waiting"))
        await model.abortBlockedPrompt(session: id)
        model.noteFleet(snapshot(activity: "waiting"))
        await model.abortBlockedPrompt(session: id)

        // The episode resolves...
        model.noteFleet(snapshot(activity: "busy"))
        // ...and a second, genuine episode begins.
        model.noteFleet(snapshot(activity: "waiting"))
        await model.abortBlockedPrompt(session: id)

        let tokens: [UUID] = model.sentCommands.compactMap {
            if case .abortPrompt(let sentID, let token) = $0, sentID == id { return token }
            return nil
        }
        XCTAssertEqual(tokens.count, 3, "all three taps must still reach sendPrompt")
        XCTAssertEqual(
            tokens[0], tokens[1],
            "still \"waiting\" across snapshots must not clear the token mid-episode"
        )
        XCTAssertNotEqual(
            tokens[1], tokens[2],
            "a resolved episode (activity left \"waiting\") must not carry its token into the next"
        )
    }
}
