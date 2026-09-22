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
/// | Progress clears the error | `testProgressClearsTheErrorAndDisarms` |
/// | Tab closed | `testClosingTheTabClearsRetryState` |
/// | Preference off | `testNothingArmsWhenThePreferenceIsOff`, and
///   `testTurningThePreferenceOffMidBackoffStopsIt` for the mid-outage toggle |
/// | Nothing types twice | `testOneTickInsideASettleWindowTypesOnce` |
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

    /// The failure this whole feature exists for — claude's own record for an overloaded API.
    /// Carries no retry state, because an agent's report never does: that is the store's to
    /// add, which is what keeps `setAPIError` the single writer.
    private static let transient = SessionAPIError(status: 529, kind: "overloaded", isTransient: true)
    /// The failure that must never be retried. Retrying a malformed request just re-sends it.
    private static let permanent = SessionAPIError(status: 400, kind: "invalid_request", isTransient: false)

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

        XCTAssertEqual(harness.store.pendingPrompts[harness.tab]?.text, SessionStore.resumePrompt,
                       "the nudge goes through the queue that already cancels on busy")
        XCTAssertEqual(harness.store.apiErrors[harness.tab]?.retryAttempt, 2)
        assertDue(harness.store.apiErrors[harness.tab]?.nextRetryAt, rung: 60, from: due,
                  "the rung must advance with the attempt")

        harness.store.maintenanceTickForTesting()

        XCTAssertEqual(harness.spy.sent, [SessionStore.resumePrompt])
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

        harness.store.closeSession(harness.tab)

        XCTAssertNil(harness.store.apiErrors[harness.tab], "the entry goes with the tab")
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
        XCTAssertEqual(harness.spy.sent, [SessionStore.resumePrompt], "typed exactly once")
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
}
