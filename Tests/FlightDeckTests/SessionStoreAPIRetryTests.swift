import XCTest
import FleetKit
@testable import FlightDeck

/// **The retry scheduler, and every stop that makes an unbounded loop safe.**
///
/// The loop has no attempt cap on purpose — an outage is ridden at one nudge per fifteen
/// minutes for as long as it lasts — so the stops are the whole safety argument, not a
/// postscript to it. §4.3 of the design doc lists them as a table, and this file is that
/// table: one test per row, each written so that deleting the stop it names turns it red.
///
/// | Stop | The test that would fail without it |
/// |---|---|
/// | Not transient | `testAPermanentErrorDoesNotArm` |
/// | Agent has no classifier | `testNothingArmsForAnAgentWithNoTurnRecovery` |
/// | The session started working | `testGoingBusyCancelsTheQueuedNudge` |
/// | The session was ALREADY working | `testNothingQueuesIntoASessionThatWasAlreadyBusy`,
///   and `testACodexTabIsRetriedAndIsRefusedWhileItIsBusy` for the agent it bites hardest |
/// | Progress clears the error | `testProgressClearsTheErrorAndDisarms` |
/// | Tab closed | `testClosingTheTabClearsRetryState` |
/// | Preference off | `testNothingArmsWhenThePreferenceIsOff`, and
///   `testTurningThePreferenceOffMidBackoffStopsIt` for the mid-outage toggle |
/// | Nothing types twice | `testOneTickInsideASettleWindowTypesOnce` |
///
/// **And the stop that is not a stop: the backoff itself.** The nudge is a user record, so
/// typing it produces progress, and progress clears the error the rung lives in. Without the
/// episode memory the ladder would be destroyed by the very nudge it scheduled and a long
/// outage would be ridden at roughly a nudge every 45 seconds, forever.
/// `testTheLadderClimbsAcrossTheNudgeThatClearsTheError` is the round trip that proves it;
/// every other rung assertion here is reachable without ever making that trip.
///
/// **Time is driven by assignment, never by sleeping.** `SessionStore.now` is the existing
/// test seam and every deadline in the scheduler is read through it, so a test reaches a
/// fifteen-minute rung by moving the clock and calling `maintenanceTickForTesting()`.
@MainActor
final class SessionStoreAPIRetryTests: XCTestCase {

    // MARK: - Doubles

    private final class StubProvider: SurfaceProvider {
        func makeSurface(_ config: Ghostty.SurfaceConfiguration) -> Ghostty.SurfaceView? { nil }
        func tick() {}
        var defaultFontSize: Float { 12 }
    }

    private final class MemoryPreferences: PreferencesPersisting {
        var stored: Preferences?
        func load() -> Preferences? { stored }
        func save(_ preferences: Preferences) { stored = preferences }
    }

    private struct SilentReporter: AgentLaunchFailureReporting {
        func report(_ error: AgentLaunchError) {}
    }

    /// Enough of an app-server to create and settle a codex thread with no `codex` process
    /// ever spawned — same shape as `SessionStoreMaintenanceTickTests.ScriptedTransport`.
    private final class ScriptedTransport: CodexTransport {
        var onLine: ((String) -> Void)?
        func send(_ line: String) {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8))
                    as? [String: Any],
                  let method = obj["method"] as? String, let id = obj["id"] as? Int else { return }
            switch method {
            case "thread/start":
                onLine?(#"{"id":\#(id),"result":{"thread":{"id":"\#(Self.thread)","cwd":"/w/a","path":"/r/x.jsonl"}}}"#)
            default:
                onLine?(#"{"id":\#(id),"result":{}}"#)
            }
        }
        static let thread = "01a018c3-4f2e-7c11-9d3a-2b6e5c04af71"
    }

    private struct CodexTabUnavailable: Error {}

    /// A hand-driven clock. A reference type because `SessionStore.now` is an escaping
    /// closure and the closure must see later assignments — and because capturing the box
    /// rather than the harness keeps the store out of its own `now`.
    private final class Clock {
        var time = Date(timeIntervalSince1970: 1_700_000_000)
    }

    /// One live claude tab, idle, with a spy that can be typed into and a clock a test moves
    /// by hand. Claude rather than codex because this file is about the *scheduler*: claude's
    /// tab needs no app-server to exist, and `ClaudeTurnRecovery` defers to the record's own
    /// `isTransient`, so a fixture error can be made transient or permanent by one field.
    /// `SessionStoreMaintenanceTickTests` already proves the tick itself reaches a codex-only
    /// fleet, which is the agent-independence this would otherwise have to re-prove.
    private final class Harness {
        let store: SessionStore
        let preferences: PreferencesStore
        let tab: UUID
        let spy: SpyInjector
        private let clock: Clock

        init(store: SessionStore, preferences: PreferencesStore, tab: UUID,
             spy: SpyInjector, clock: Clock) {
            self.store = store
            self.preferences = preferences
            self.tab = tab
            self.spy = spy
            self.clock = clock
        }

        /// What `store.now()` answers. Assign to move time.
        var time: Date {
            get { clock.time }
            set { clock.time = newValue }
        }
    }

    private var projectsRoot: URL!
    private var tmp: URL { URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true) }

    override func setUpWithError() throws {
        projectsRoot = tmp.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: projectsRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: projectsRoot)
    }

    private func makeHarness(autoRetry: Bool = true) -> Harness {
        let preferences = PreferencesStore(persistence: MemoryPreferences())
        preferences.autoRetriesAPIErrors = autoRetry
        let store = SessionStore(
            provider: StubProvider(), persistence: nil, preferences: preferences
        )
        // Never the user's real `~/.claude`: a tab created here starts a transcript watcher
        // and a status watcher, both of which read a root off the store.
        store.transcriptsRootOverride = projectsRoot
        store.statusRootOverride = projectsRoot
        store.launchFailureReporter = SilentReporter()
        let spy = SpyInjector()
        store.injectorOverride = spy
        store.injectionSettle = { $0() }
        let clock = Clock()
        store.now = { clock.time }
        let tab = store.newSession(in: tmp).id
        store.applyRegistryForTesting([tab: SessionStatus(activity: .idle)])
        // The tab's own creation may have typed; this file only ever asserts about the nudge.
        spy.events.removeAll()
        return Harness(store: store, preferences: preferences, tab: tab, spy: spy, clock: clock)
    }

    /// Codex's real idle composer shape — one row, the placeholder, and the status-line footer
    /// `CodexTextChannel.hasFooter` requires directly beneath it.
    private static let codexComposerViewport =
        "› Ask Codex to do anything\n\n  gpt-5.6-sol default · /tmp/work"

    /// One live codex tab, with **no `applyRegistryForTesting` call anywhere** — codex has no
    /// status registry, and the whole point of the codex half of this file is what its status
    /// is without one. See `testACodexTabIsRetriedAndIsRefusedWhileItIsBusy`.
    private func makeCodexHarness(autoRetry: Bool = true) async throws -> Harness {
        let preferences = PreferencesStore(persistence: MemoryPreferences())
        preferences.autoRetriesAPIErrors = autoRetry
        let store = SessionStore(
            provider: StubProvider(), persistence: nil, preferences: preferences
        )
        store.transcriptsRootOverride = projectsRoot
        store.statusRootOverride = projectsRoot
        // Never the user's real `~/.codex/session_index.jsonl`: this creates a codex tab.
        store.codexIndexURLOverride = projectsRoot.appendingPathComponent("session_index.jsonl")
        store.launchFailureReporter = SilentReporter()
        let spy = SpyInjector()
        spy.viewportOverride = Self.codexComposerViewport
        store.injectorOverride = spy
        store.injectionSettle = { $0() }
        let clock = Clock()
        store.now = { clock.time }
        // Filed under the account the tab will actually resolve to. This store HAS
        // preferences, so the accounts migration seeds a built-in account per agent and the
        // key is that account's id, not nil — an override filed under nil would silently not
        // be found, and for codex "not found" means spawning a real `codex app-server`.
        store.overrideAdapter(
            CodexAdapter(rpc: CodexRPC(transport: ScriptedTransport()), rolloutExists: { _ in true }),
            for: .codex, account: preferences.resolvedAccountID(for: .codex, in: nil)
        )
        guard case .success(let tab) = await store.createSession(agent: .codex, in: tmp.path) else {
            XCTFail("codex tab creation must succeed against a scripted transport")
            throw CodexTabUnavailable()
        }
        spy.events.removeAll()
        return Harness(store: store, preferences: preferences, tab: tab, spy: spy, clock: clock)
    }

    /// The nudge text an agent's own recovery asks for.
    ///
    /// Asserting against this rather than against `SessionStore.resumePrompt` is what pins the
    /// per-agent path: the two strings are equal today, so a `resumePrompt` assertion would
    /// stay green even if the scheduler ignored the capability and typed the constant. Returns
    /// non-optionally so a missing recovery fails loudly instead of matching a nil expectation.
    private func resumeText(for agent: AgentID,
                            file: StaticString = #filePath, line: UInt = #line) -> String {
        guard let text = agent.turnRecovery?.resumeText else {
            XCTFail("\(agent) has no turn recovery, so there is no nudge text to assert against",
                    file: file, line: line)
            return "<no recovery>"
        }
        return text
    }

    /// The failure this whole feature exists for — claude's own record for an overloaded API.
    /// Carries no retry state, because an agent's report never does: that is the store's to
    /// add, which is what keeps `setAPIError` the single writer.
    private static let transient = SessionAPIError(status: 529, kind: "overloaded", isTransient: true)
    /// The failure that must never be retried. Retrying a malformed request just re-sends it.
    private static let permanent = SessionAPIError(status: 400, kind: "invalid_request", isTransient: false)
    /// Codex's own vocabulary for a capacity failure — the rollout's snake_case spelling,
    /// captured by the probe and matched by `CodexTurnRecovery`'s allowlist.
    ///
    /// **Deliberately not `Self.transient`.** Claude's `"overloaded"` is not on codex's list,
    /// and the first draft of the codex test below used the shared fixture and failed to arm —
    /// which is the classifier being genuinely consulted per agent rather than the scheduler
    /// deciding transience for itself. `isTransient` is set as `CodexEventMapper` would set
    /// it; `CodexTurnRecovery` ignores the flag and reads `kind`, so it is not a backdoor.
    private static let codexTransient = SessionAPIError(
        status: 429, kind: "response_too_many_failed_attempts", isTransient: true)

    /// `nextRetryAt` carries ±10% jitter by design, so it is asserted as a window rather than
    /// a value. The windows of two adjacent rungs never overlap — rung 1 tops out at 33s and
    /// rung 2 starts at 54s — which is what lets these tests tell one rung from the next.
    private func assertDue(_ due: Date?, rung: TimeInterval, from start: Date,
                           _ message: String = "",
                           file: StaticString = #filePath, line: UInt = #line) {
        guard let due else {
            return XCTFail("expected a retry armed at the \(rung)s rung. \(message)",
                           file: file, line: line)
        }
        let delay = due.timeIntervalSince(start)
        XCTAssertGreaterThanOrEqual(
            delay, rung * 0.9,
            "\(delay)s is below the \(rung)s rung's jitter window. \(message)",
            file: file, line: line)
        XCTAssertLessThanOrEqual(
            delay, rung * 1.1,
            "\(delay)s is above the \(rung)s rung's jitter window. \(message)",
            file: file, line: line)
    }

    // MARK: - The ladder

    func testTheLadderRampsThenSaturatesAtTheFloor() {
        XCTAssertEqual(SessionStore.retryDelay(forAttempt: 1, jitter: 0), 30)
        XCTAssertEqual(SessionStore.retryDelay(forAttempt: 2, jitter: 0), 60)
        XCTAssertEqual(SessionStore.retryDelay(forAttempt: 5, jitter: 0), 480)
        XCTAssertEqual(SessionStore.retryDelay(forAttempt: 6, jitter: 0), 900)
        XCTAssertEqual(SessionStore.retryDelay(forAttempt: 99, jitter: 0), 900)
        // Stated as the relationship rather than as the number, so extending the ladder
        // cannot silently leave the floor a rung out of step with it.
        XCTAssertEqual(
            SessionStore.retryDelay(forAttempt: SessionStore.retryBackoff.count + 1, jitter: 0),
            SessionStore.retryBackoffFloor,
            "the floor must begin exactly one rung past the ladder's last entry")
        // `retryBackoff[attempt - 1]` TRAPS on a zero attempt, and the bounds check above it
        // (`attempt <= count`) waves zero straight through — so an off-by-one in a *computed*
        // attempt, which is how `restore` selects the floor, would crash the app rather than
        // pick a wrong delay.
        XCTAssertEqual(SessionStore.retryDelay(forAttempt: 0, jitter: 0), 30,
                       "a zero attempt must clamp to the first rung, never trap")
        XCTAssertEqual(SessionStore.retryDelay(forAttempt: -3, jitter: 0), 30)
    }

    func testJitterStaysWithinTenPercent() {
        XCTAssertEqual(SessionStore.retryDelay(forAttempt: 1, jitter: 0.1), 33, accuracy: 0.001)
        XCTAssertEqual(SessionStore.retryDelay(forAttempt: 1, jitter: -0.1), 27, accuracy: 0.001)
        // The floor is jittered too. A fleet that all fell over on the same 529 spends the
        // rest of a long outage on the floor, so a floor without jitter would re-create the
        // lockstep herd exactly where it lasts longest.
        XCTAssertEqual(SessionStore.retryDelay(forAttempt: 99, jitter: 0.1), 990, accuracy: 0.001)
    }

    // MARK: - Arming

    func testATransientErrorArmsTheFirstAttempt() {
        let harness = makeHarness()

        harness.store.apply(.apiError(Self.transient), to: harness.tab)

        guard let armed = harness.store.apiErrors[harness.tab] else {
            return XCTFail("arming must not replace the error; the badge is still true")
        }
        XCTAssertEqual(armed.retryAttempt, 1)
        assertDue(armed.nextRetryAt, rung: 30, from: harness.time)
        XCTAssertEqual(armed.status, 529, "arming must not disturb what the badge reports")
        XCTAssertEqual(armed.kind, "overloaded")
    }

    /// Retrying a request the API rejected on its merits just re-sends it. `retries` is the
    /// agent's own answer — claude's is the record's `isTransient` — and this is the one row
    /// of the stop table that the arming gate cannot decide for itself.
    func testAPermanentErrorDoesNotArm() {
        let harness = makeHarness()

        harness.store.apply(.apiError(Self.permanent), to: harness.tab)

        XCTAssertNotNil(harness.store.apiErrors[harness.tab],
                        "the failure is still real; only the loop is refused")
        XCTAssertNil(harness.store.apiErrors[harness.tab]?.retryAttempt)
        XCTAssertNil(harness.store.apiErrors[harness.tab]?.nextRetryAt)

        harness.time += 3600
        harness.store.maintenanceTickForTesting()
        XCTAssertNil(harness.store.pendingPrompts[harness.tab],
                     "an unarmed error must never come due, however long it sits")
        XCTAssertTrue(harness.spy.events.isEmpty, "not one keystroke")
    }

    /// Off is the default, and this feature types into a terminal, so the preference is the
    /// stop that has to hold before any of the others are even consulted.
    func testNothingArmsWhenThePreferenceIsOff() {
        let harness = makeHarness(autoRetry: false)

        harness.store.apply(.apiError(Self.transient), to: harness.tab)

        XCTAssertNotNil(harness.store.apiErrors[harness.tab], "the badge is unconditional")
        XCTAssertNil(harness.store.apiErrors[harness.tab]?.retryAttempt,
                     "the same error that arms in testATransientErrorArmsTheFirstAttempt")
        XCTAssertNil(harness.store.apiErrors[harness.tab]?.nextRetryAt)

        harness.time += 3600
        harness.store.maintenanceTickForTesting()
        XCTAssertNil(harness.store.pendingPrompts[harness.tab])
        XCTAssertTrue(harness.spy.events.isEmpty, "not one keystroke")
    }

    /// **The fail-closed arm, and the only one with no reachable fixture.** Both shipped
    /// agents answer `turnRecovery` non-nil, so the `nil` refusal — an agent added later
    /// retries nothing until someone writes and tests its classifier — is unreachable without
    /// `turnRecoveryOverride`. The neighbour that proves this fixture could otherwise have
    /// armed is `testATransientErrorArmsTheFirstAttempt`: identical store, identical error,
    /// differing only in the line below.
    func testNothingArmsForAnAgentWithNoTurnRecovery() {
        let harness = makeHarness()
        harness.store.turnRecoveryOverride = { _ in nil }

        harness.store.apply(.apiError(Self.transient), to: harness.tab)

        XCTAssertNotNil(harness.store.apiErrors[harness.tab])
        XCTAssertNil(harness.store.apiErrors[harness.tab]?.retryAttempt,
                     "an agent with no classifier must never cause unattended typing")
        XCTAssertNil(harness.store.apiErrors[harness.tab]?.nextRetryAt)

        harness.time += 3600
        harness.store.maintenanceTickForTesting()
        XCTAssertTrue(harness.spy.events.isEmpty, "not one keystroke")
    }

    // MARK: - The tick

    /// The whole mechanism in one test: coming due queues the nudge into the *existing*
    /// `pendingPrompts`, advances the rung, and the queue's own flush types it on the next
    /// tick. Both halves are asserted because they have different guards behind them — a
    /// scheduler that queued nothing and a queue that never drained would each leave the
    /// other's assertion green.
    func testTheDueAttemptQueuesTheNudgeAndAdvancesTheRung() {
        let harness = makeHarness()
        harness.store.apply(.apiError(Self.transient), to: harness.tab)
        guard let due = harness.store.apiErrors[harness.tab]?.nextRetryAt else {
            return XCTFail("nothing was armed, so there is no tick to test")
        }

        harness.time = due
        harness.store.maintenanceTickForTesting()

        XCTAssertEqual(harness.store.pendingPrompts[harness.tab]?.text, resumeText(for: .claude),
                       "the nudge goes through the queue that already cancels on busy")
        XCTAssertEqual(harness.store.apiErrors[harness.tab]?.retryAttempt, 2)
        assertDue(harness.store.apiErrors[harness.tab]?.nextRetryAt, rung: 60, from: due,
                  "the rung must advance with the attempt")

        harness.store.maintenanceTickForTesting()

        XCTAssertEqual(harness.spy.sent, [resumeText(for: .claude)])
        XCTAssertEqual(harness.spy.events.last, .ret, "Return must arrive after the paste closes")
        XCTAssertNil(harness.store.pendingPrompts[harness.tab], "typed, so retired")
    }

    func testAnAttemptIsNotQueuedBeforeItIsDue() {
        let harness = makeHarness()
        harness.store.apply(.apiError(Self.transient), to: harness.tab)
        guard let due = harness.store.apiErrors[harness.tab]?.nextRetryAt else {
            return XCTFail("nothing was armed, so there is no tick to test")
        }

        harness.time = due.addingTimeInterval(-1)
        harness.store.maintenanceTickForTesting()

        XCTAssertNil(harness.store.pendingPrompts[harness.tab], "one second early is early")
        XCTAssertTrue(harness.spy.events.isEmpty, "not one keystroke")
        XCTAssertEqual(harness.store.apiErrors[harness.tab]?.retryAttempt, 1,
                       "a tick that did nothing must not advance the rung")
        XCTAssertEqual(harness.store.apiErrors[harness.tab]?.nextRetryAt, due,
                       "nor re-roll the schedule, which would let the ladder drift on idle ticks")
    }

    // MARK: - The stops

    /// The turn came back on its own. `.apiError(nil)` is what a clean record reports, and it
    /// must take the schedule with it — an error entry is the only thing holding one.
    func testProgressClearsTheErrorAndDisarms() {
        let harness = makeHarness()
        harness.store.apply(.apiError(Self.transient), to: harness.tab)
        XCTAssertEqual(harness.store.apiErrors[harness.tab]?.retryAttempt, 1, "armed to begin with")

        harness.store.apply(.apiError(nil), to: harness.tab)

        XCTAssertNil(harness.store.apiErrors[harness.tab], "the entry goes, schedule included")
        harness.time += 3600
        harness.store.maintenanceTickForTesting()
        XCTAssertNil(harness.store.pendingPrompts[harness.tab])
        XCTAssertTrue(harness.spy.events.isEmpty, "nothing is left to retry")
    }

    /// The reason the nudge goes through `pendingPrompts` at all. The user typing, or the
    /// agent picking its own turn back up, makes the session busy — and `cancelSupersededPrompts`
    /// drops the queued nudge without this feature needing a rule of its own.
    func testGoingBusyCancelsTheQueuedNudge() {
        let harness = makeHarness()
        harness.store.apply(.apiError(Self.transient), to: harness.tab)
        guard let due = harness.store.apiErrors[harness.tab]?.nextRetryAt else {
            return XCTFail("nothing was armed, so there is no nudge to cancel")
        }
        harness.time = due
        harness.store.maintenanceTickForTesting()
        XCTAssertNotNil(harness.store.pendingPrompts[harness.tab], "queued, and not yet typed")

        harness.store.cancelSupersededPromptsForTesting([
            StatusTransition(id: harness.tab,
                             old: SessionStatus(activity: .idle),
                             new: SessionStatus(activity: .busy))
        ])

        XCTAssertNil(harness.store.pendingPrompts[harness.tab],
                     "something is already in flight; the nudge would be a second instruction")
        harness.store.maintenanceTickForTesting()
        XCTAssertTrue(harness.spy.events.isEmpty, "and nothing types it after the fact")
    }

    /// The one stop a user expects to be instant: the toggle goes off mid-outage and the loop
    /// stops on the very next tick, without the badge changing — the failure is still true.
    func testTurningThePreferenceOffMidBackoffStopsIt() {
        let harness = makeHarness()
        harness.store.apply(.apiError(Self.transient), to: harness.tab)
        XCTAssertEqual(harness.store.apiErrors[harness.tab]?.retryAttempt, 1, "armed to begin with")

        harness.preferences.autoRetriesAPIErrors = false
        harness.store.maintenanceTickForTesting()

        XCTAssertNil(harness.store.apiErrors[harness.tab]?.retryAttempt, "disarmed on the next tick")
        XCTAssertNil(harness.store.apiErrors[harness.tab]?.nextRetryAt)
        XCTAssertEqual(harness.store.apiErrors[harness.tab]?.status, 529,
                       "the badge stays — only the loop stopped")
        XCTAssertEqual(harness.store.apiErrors[harness.tab]?.kind, "overloaded")

        harness.time += 3600
        harness.store.maintenanceTickForTesting()
        XCTAssertNil(harness.store.pendingPrompts[harness.tab])
        XCTAssertTrue(harness.spy.events.isEmpty, "not one keystroke after the toggle")
    }

    /// A schedule for a tab that no longer exists would outlive every path that could clear
    /// it — the same argument `closeSession` already makes for `unreadIdle` and the prompt
    /// queue.
    func testClosingTheTabClearsRetryState() {
        let harness = makeHarness()
        harness.store.apply(.apiError(Self.transient), to: harness.tab)
        XCTAssertNotNil(harness.store.apiErrors[harness.tab]?.retryAttempt, "armed to begin with")

        XCTAssertEqual(harness.store.retryEpisodeCountForTesting, 1, "and remembered")

        harness.store.closeSession(harness.tab)

        XCTAssertNil(harness.store.apiErrors[harness.tab], "the entry goes with the tab")
        XCTAssertEqual(harness.store.retryEpisodeCountForTesting, 0,
                       "and so does the ladder memory, which deliberately outlives the entry — "
                       + "a reopened tab reusing this id must start at rung 1")
        harness.time += 3600
        harness.store.maintenanceTickForTesting()
        XCTAssertNil(harness.store.pendingPrompts[harness.tab])
        XCTAssertTrue(harness.spy.events.isEmpty, "a closed tab cannot be typed into")
    }

    /// **Two ticks, one nudge.** The tick runs from two sources — `applyRegistry`'s `defer`
    /// and the `WatchClock` — so a second one landing inside the first drive's settle window
    /// is ordinary, not exotic. Driven by holding `injectionSettle`'s continuation rather than
    /// running it inline, which is the only way to be genuinely *inside* the window; with an
    /// inline settle the drive is over before the second tick exists and the test would prove
    /// nothing.
    func testOneTickInsideASettleWindowTypesOnce() {
        let harness = makeHarness()
        var pending: [() -> Void] = []
        harness.store.injectionSettle = { pending.append($0) }
        harness.store.apply(.apiError(Self.transient), to: harness.tab)
        guard let due = harness.store.apiErrors[harness.tab]?.nextRetryAt else {
            return XCTFail("nothing was armed, so there is no drive to interrupt")
        }

        harness.time = due
        harness.store.maintenanceTickForTesting()          // queues the nudge
        harness.store.maintenanceTickForTesting()          // starts the drive: kill, then settle
        XCTAssertEqual(harness.spy.events, [.killLine], "the drive is suspended mid-settle")
        XCTAssertEqual(pending.count, 1)

        harness.store.maintenanceTickForTesting()          // lands inside the settle window

        XCTAssertEqual(harness.spy.events, [.killLine],
                       "not one keystroke while the first drive is still resolving")
        XCTAssertEqual(pending.count, 1, "and no second drive was started")

        while !pending.isEmpty { pending.removeFirst()() }
        XCTAssertEqual(harness.spy.sent, [resumeText(for: .claude)], "typed exactly once")
        XCTAssertNil(harness.store.pendingPrompts[harness.tab], "typed, so retired")
    }

    /// **An identical re-report must not restart the ladder.** `armed` draws a fresh
    /// `nextRetryAt` every time it runs, so handing it a repeat of the same failure would
    /// slide a tab that had climbed towards the fifteen-minute floor back down to thirty
    /// seconds — and would rewrite sessions.json for a change nobody made, which is the
    /// second case `apply`'s unchanged guard was already written for. The watcher suppresses
    /// most repeats itself; a restore-seeded error re-reported by the first live scan is the
    /// one that reaches here.
    ///
    /// The second half is what stops the guard from being too broad: a *different* failure is
    /// real news and must still land, and be judged on its own merits.
    func testAReReportOfTheSameFailureDoesNotRestartTheLadder() {
        let harness = makeHarness()
        harness.store.apply(.apiError(Self.transient), to: harness.tab)
        guard let first = harness.store.apiErrors[harness.tab]?.nextRetryAt else {
            return XCTFail("nothing was armed, so there is no ladder to restart")
        }
        // Climb a rung first, so a reset would show up as a visibly *shorter* wait rather
        // than merely a differently-jittered one.
        harness.time = first
        harness.store.maintenanceTickForTesting()
        guard let second = harness.store.apiErrors[harness.tab]?.nextRetryAt else {
            return XCTFail("the tick must leave the tab armed at the next rung")
        }
        XCTAssertEqual(harness.store.apiErrors[harness.tab]?.retryAttempt, 2)

        harness.store.apply(.apiError(Self.transient), to: harness.tab)

        XCTAssertEqual(harness.store.apiErrors[harness.tab]?.retryAttempt, 2, "the rung stands")
        XCTAssertEqual(harness.store.apiErrors[harness.tab]?.nextRetryAt, second,
                       "and so does the schedule — a re-report is not a new failure")

        harness.store.apply(.apiError(Self.permanent), to: harness.tab)

        XCTAssertEqual(harness.store.apiErrors[harness.tab]?.kind, "invalid_request",
                       "a different failure IS news and must still land")
        XCTAssertNil(harness.store.apiErrors[harness.tab]?.retryAttempt,
                     "and is re-judged on its own merits, not left on the old schedule")
    }

    // MARK: - Already working when the rung came due

    /// **`cancelSupersededPrompts` cannot cover this, and that is the defect.** It fires on a
    /// `StatusTransition` INTO busy, and it runs inside `applyRegistry` above the
    /// `defer { maintenanceTick() }` — so a session that was *already* busy when the rung came
    /// due produces no edge at all and nothing cancels the nudge. `inject` is no help either:
    /// its idle/busy gate was deliberately removed in favour of composer presence.
    ///
    /// The tab is put busy BEFORE the clock reaches the rung and left there, so no transition
    /// into busy ever happens inside the window this test measures.
    func testNothingQueuesIntoASessionThatWasAlreadyBusy() {
        let harness = makeHarness()
        harness.store.apply(.apiError(Self.transient), to: harness.tab)
        guard let due = harness.store.apiErrors[harness.tab]?.nextRetryAt else {
            return XCTFail("nothing was armed, so there is no rung to come due")
        }
        harness.store.applyRegistryForTesting([harness.tab: SessionStatus(activity: .busy)])

        harness.time = due
        harness.store.maintenanceTickForTesting()

        XCTAssertNil(harness.store.pendingPrompts[harness.tab],
                     "the user is working in there; the resume text would land in their turn")
        XCTAssertTrue(harness.spy.events.isEmpty, "not one keystroke")
        XCTAssertEqual(harness.store.apiErrors[harness.tab]?.retryAttempt, 1,
                       "deferred, not consumed — no rung is spent on a nudge nobody sent")
        XCTAssertEqual(harness.store.apiErrors[harness.tab]?.nextRetryAt, due,
                       "and the schedule stands, so it goes out as soon as the tab is free")

        // `waiting` is refused on the same footing: a permission dialog is the user's turn.
        harness.store.applyRegistryForTesting([harness.tab: SessionStatus(activity: .waiting)])
        harness.store.maintenanceTickForTesting()
        XCTAssertNil(harness.store.pendingPrompts[harness.tab], "a dialog is someone's turn too")

        // The turn ends, still failed. Now — and only now — the nudge is allowed.
        harness.store.applyRegistryForTesting([harness.tab: SessionStatus(activity: .idle)])
        harness.store.maintenanceTickForTesting()
        XCTAssertEqual(harness.store.pendingPrompts[harness.tab]?.text, resumeText(for: .claude),
                       "the deferral is a wait, not a loss")
        XCTAssertEqual(harness.store.apiErrors[harness.tab]?.retryAttempt, 2)
    }

    /// **The codex half, and the reason the activity guard could not simply be `== .idle`.**
    ///
    /// Codex has no status registry, so `applyRegistry` never writes its status and this
    /// harness never calls `applyRegistryForTesting`. The first assertion establishes what
    /// `statuses[id]` therefore actually holds, rather than assuming it: `.idle`, seeded at
    /// attachment by the `!hasStatusRegistry` branch in `startWatching` and written by
    /// `applyActivity` from `CodexEventMapper` thereafter. Had it been nil, a guard spelled
    /// `statuses[id]?.activity == .idle` would have disabled retry for codex outright —
    /// silently re-creating the claude-only failure Task 5 exists to prevent.
    ///
    /// Codex is also where the busy case stops being a race: `CodexEventMapper` emits
    /// `.apiError(nil)` only on `task_complete`, so a tab whose last turn failed and whose
    /// user then retried by hand stays armed for the whole of that new turn — and rung 1 is
    /// thirty seconds.
    func testACodexTabIsRetriedAndIsRefusedWhileItIsBusy() async throws {
        let harness = try await makeCodexHarness()

        XCTAssertEqual(harness.store.statuses[harness.tab]?.activity, .idle,
                       "a codex tab has a real status with no registry tick ever having run")

        harness.store.apply(.apiError(Self.codexTransient), to: harness.tab)
        guard let due = harness.store.apiErrors[harness.tab]?.nextRetryAt else {
            return XCTFail("codex must arm like claude — the loop never learns an agent's name")
        }

        // The user retried by hand. The error is still standing: codex clears it only at
        // `task_complete`.
        harness.store.apply(.activity(.busy), to: harness.tab)
        harness.time = due
        harness.store.maintenanceTickForTesting()

        XCTAssertNil(harness.store.pendingPrompts[harness.tab],
                     "thirty seconds into the user's own turn is exactly when this bites")
        XCTAssertTrue(harness.spy.events.isEmpty, "not one keystroke into codex's composer")
        XCTAssertEqual(harness.store.apiErrors[harness.tab]?.retryAttempt, 1, "deferred, not spent")

        // That turn ends without clearing the failure.
        harness.store.apply(.activity(.idle), to: harness.tab)
        harness.store.maintenanceTickForTesting()
        XCTAssertEqual(harness.store.pendingPrompts[harness.tab]?.text, resumeText(for: .codex),
                       "and codex is nudged with its OWN recovery's text")

        harness.store.maintenanceTickForTesting()
        XCTAssertEqual(harness.spy.sent, [resumeText(for: .codex)],
                       "typed into codex's real composer, through the one existing queue")
    }

    // MARK: - The ladder across a round trip

    /// **The regression the episode memory exists for, and the one shape every other rung
    /// assertion in this file misses.** They all check the rung inside a single unbroken
    /// error entry. Production never stays there: the nudge is itself a user record, so
    /// typing it produces progress, progress reports `.apiError(nil)`, and that removes the
    /// entry — rung and all. The retry fails again seconds later and a fresh error arrives.
    ///
    /// Without a memory outside the entry that fresh error arms at rung 1 every time, and a
    /// week-long outage is ridden at a nudge every ~45s forever rather than one per fifteen
    /// minutes. The full round trip is run twice, so a fix that merely remembered "not the
    /// first failure" and stuck at rung 2 fails too.
    func testTheLadderClimbsAcrossTheNudgeThatClearsTheError() {
        let harness = makeHarness()
        harness.store.apply(.apiError(Self.transient), to: harness.tab)
        guard let firstDue = harness.store.apiErrors[harness.tab]?.nextRetryAt else {
            return XCTFail("nothing was armed, so there is no ladder to climb")
        }
        assertDue(firstDue, rung: 30, from: harness.time)

        harness.time = firstDue
        harness.store.maintenanceTickForTesting()   // queues the nudge
        harness.store.maintenanceTickForTesting()   // and types it
        XCTAssertEqual(harness.spy.sent, [resumeText(for: .claude)])
        XCTAssertNil(harness.store.pendingPrompts[harness.tab], "typed, so retired")

        // What typing it does in production: a user record lands, the transcript reports
        // progress, and progress clears the entry the rung was living in.
        harness.store.apply(.apiError(nil), to: harness.tab)
        XCTAssertNil(harness.store.apiErrors[harness.tab])

        // The revived turn dies on the same outage moments later.
        harness.time = firstDue.addingTimeInterval(15)
        harness.store.apply(.apiError(Self.transient), to: harness.tab)

        XCTAssertEqual(harness.store.apiErrors[harness.tab]?.retryAttempt, 2,
                       "the ladder must survive the very event it scheduled")
        assertDue(harness.store.apiErrors[harness.tab]?.nextRetryAt, rung: 60, from: harness.time,
                  "a second rung 1 here IS the nudge-every-45-seconds bug")

        // Round two, to prove it keeps climbing rather than parking on rung 2.
        guard let secondDue = harness.store.apiErrors[harness.tab]?.nextRetryAt else {
            return XCTFail("the second rung must be armed")
        }
        harness.time = secondDue
        harness.store.maintenanceTickForTesting()
        harness.store.maintenanceTickForTesting()
        harness.store.apply(.apiError(nil), to: harness.tab)
        harness.time = secondDue.addingTimeInterval(15)
        harness.store.apply(.apiError(Self.transient), to: harness.tab)

        XCTAssertEqual(harness.store.apiErrors[harness.tab]?.retryAttempt, 3)
        assertDue(harness.store.apiErrors[harness.tab]?.nextRetryAt, rung: 120, from: harness.time)
    }

    /// The other half of the decay ruling, and it is correct behaviour rather than a
    /// concession: a session that genuinely recovers, runs clean for longer than the floor,
    /// and only then fails again is a NEW outage and must start at thirty seconds. Decay is
    /// by elapsed time precisely so nothing has to work out who caused the progress.
    func testAnEpisodeDecaysSoAMuchLaterFailureStartsOver() {
        let harness = makeHarness()
        harness.store.apply(.apiError(Self.transient), to: harness.tab)
        guard let due = harness.store.apiErrors[harness.tab]?.nextRetryAt else {
            return XCTFail("nothing was armed, so there is no episode to decay")
        }
        harness.time = due
        harness.store.maintenanceTickForTesting()
        harness.store.maintenanceTickForTesting()
        harness.store.apply(.apiError(nil), to: harness.tab)
        XCTAssertEqual(harness.store.retryEpisodeCountForTesting, 1,
                       "the ladder is remembered across the cleared error")

        // Clean for longer than the floor.
        harness.time = due.addingTimeInterval(SessionStore.retryBackoffFloor + 1)
        harness.store.maintenanceTickForTesting()
        XCTAssertEqual(harness.store.retryEpisodeCountForTesting, 0,
                       "a decayed episode is dropped rather than leaked for the process's life")

        harness.store.apply(.apiError(Self.transient), to: harness.tab)

        XCTAssertEqual(harness.store.apiErrors[harness.tab]?.retryAttempt, 1,
                       "a new outage, not a continuation of the old one")
        assertDue(harness.store.apiErrors[harness.tab]?.nextRetryAt, rung: 30, from: harness.time)
    }

    /// The preference toggle is symmetric: off stops the loop on the next tick, on picks it
    /// back up. Before the re-arm pass, an error disarmed mid-outage stayed dead — nothing
    /// re-armed it, because the only other arming site is a *new* failure report.
    func testTurningThePreferenceBackOnResumesTheLoop() {
        let harness = makeHarness()
        harness.store.apply(.apiError(Self.transient), to: harness.tab)
        harness.preferences.autoRetriesAPIErrors = false
        harness.store.maintenanceTickForTesting()
        XCTAssertNil(harness.store.apiErrors[harness.tab]?.retryAttempt, "disarmed, as before")

        harness.preferences.autoRetriesAPIErrors = true
        harness.store.maintenanceTickForTesting()

        XCTAssertEqual(harness.store.apiErrors[harness.tab]?.retryAttempt, 1,
                       "an error still standing when the toggle comes back on is re-armed")
        assertDue(harness.store.apiErrors[harness.tab]?.nextRetryAt, rung: 30, from: harness.time)

        // And the re-arm pass judges each failure on its own merits rather than arming
        // whatever it finds — otherwise it would be a way around the allowlist.
        harness.store.apply(.apiError(Self.permanent), to: harness.tab)
        harness.store.maintenanceTickForTesting()
        XCTAssertNil(harness.store.apiErrors[harness.tab]?.retryAttempt,
                     "a permanent failure stays unarmed however many ticks pass over it")
    }

    /// The `pendingPrompts[id] == nil` guard. A nudge that is queued but not yet typed —
    /// waiting on a composer that has not appeared — must not be overwritten by the next rung
    /// coming due, and that rung must not be spent on typing that never happened.
    ///
    /// The tab is held mid-injection, which is the state a nudge waiting on a busy `inject`
    /// is genuinely in, so `flushPendingPrompts` cannot retire the entry.
    func testADueRungDoesNotOverwriteANudgeStillWaitingToBeTyped() {
        let harness = makeHarness()
        harness.store.apply(.apiError(Self.transient), to: harness.tab)
        guard let due = harness.store.apiErrors[harness.tab]?.nextRetryAt else {
            return XCTFail("nothing was armed, so there is no nudge to strand")
        }
        harness.store.holdInjectionForTesting(harness.tab)

        harness.time = due
        harness.store.maintenanceTickForTesting()
        XCTAssertEqual(harness.store.pendingPrompts[harness.tab]?.text, resumeText(for: .claude))
        XCTAssertEqual(harness.store.apiErrors[harness.tab]?.retryAttempt, 2)
        guard let second = harness.store.apiErrors[harness.tab]?.nextRetryAt else {
            return XCTFail("the second rung must be armed")
        }

        harness.time = second
        harness.store.maintenanceTickForTesting()

        XCTAssertEqual(harness.store.apiErrors[harness.tab]?.retryAttempt, 2,
                       "no rung is spent while the previous nudge is still unsent")
        XCTAssertEqual(harness.store.apiErrors[harness.tab]?.nextRetryAt, second,
                       "and its schedule is not re-rolled either")
        XCTAssertTrue(harness.spy.events.isEmpty, "nothing was typed, which is the premise")
    }
}
