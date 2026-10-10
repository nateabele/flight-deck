import XCTest
import FleetKit
import IntakeKit
@testable import FlightDeck

/// `UsageService` is where every meter meets the ledger. These drive one tick at a time against
/// a scripted environment and pin: each source lands on the right account, codex is polled at
/// most every two minutes and never without a running server, rate-limit API errors refuse the
/// account once per occurrence, manual tabs are told once per crossing, silence from the mod
/// becomes a visible error, and taps deliver only their own account's readings.
@MainActor
final class UsageServiceTests: XCTestCase {
    private var dir: URL!
    private var clock: UsageTestClock!
    private var sessions: [Session] = []
    private var apiErrors: [UUID: SessionAPIError] = [:]
    private var codexResult: [String: Any]?
    private var codexError: Error?
    private var codexReads = 0
    private var codexHangs = false
    private var seats: [SeatActivity] = []
    private var swarm: Set<UUID> = []
    /// Sessions the store has a status for. nil means every tab is live.
    private var live: Set<UUID>?
    /// The Accounts list the pools come from; nil means one entry per account, unpooled.
    private var accountList: AccountList?
    private let notifier = UsageSpyNotifier()
    private var accounts = [
        AgentAccount(id: UsageRefs.workID, agent: .claude, displayName: "Work", home: URL(fileURLWithPath: "/tmp/fd-usage/w", isDirectory: true)),
        AgentAccount(id: UsageRefs.spareID, agent: .claude, displayName: "Spare", home: URL(fileURLWithPath: "/tmp/fd-usage/s", isDirectory: true)),
        AgentAccount(id: UsageRefs.codexID, agent: .codex, displayName: "Codex", home: URL(fileURLWithPath: "/tmp/fd-usage/c", isDirectory: true)),
    ]

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("fd-usage-svc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        clock = UsageTestClock()
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func service(codexReadTimeout: TimeInterval = 20,
                         geminiUsage: @escaping @Sendable () async -> Data? = { nil }) -> UsageService {
        let c = clock!
        let env = UsageEnvironment(
            sessions: { [unowned self] in self.sessions },
            apiErrors: { [unowned self] in self.apiErrors },
            accounts: { [unowned self] in self.accounts },
            resolvedAccountID: { agent, stored in stored ?? (agent == .claude ? UsageRefs.workID : UsageRefs.codexID) },
            pools: { [unowned self] in (self.accountList ?? AccountList(entries: self.accounts.map(AccountEntry.account))).effectivePools() },
            usageDirectory: dir,
            codexRead: { [unowned self] _ in
                self.codexReads += 1
                if self.codexHangs { try await Task.sleep(for: .seconds(3600)) }
                if let e = self.codexError { throw e }
                return self.codexResult
            },
            seatActivities: { [unowned self] in self.seats },
            notifier: { [unowned self] in self.notifier },
            isSwarmSession: { [unowned self] in self.swarm.contains($0) },
            isLive: { [unowned self] in self.live?.contains($0) ?? true },
            geminiUsage: geminiUsage)
        return UsageService(environment: env, ledger: CapacityLedger(now: { c.now }), now: { c.now }, codexReadTimeout: codexReadTimeout)
    }

    private func claudeTab(on account: UUID?, conversation: UUID? = nil) -> Session {
        Session(title: "tab", workingDirectory: "/p", pinnedConversationID: conversation, agent: .claude, accountID: account)
    }

    private func writeModFile(named stem: String, percent: Double, readAt: Date) throws {
        let body = #"{"v":1,"tab":null,"session":"s","readAt":"\#(ISO8601DateFormatter().string(from: readAt))","rateLimits":[{"kind":"five_hour","percentUsed":\#(percent),"resetsAt":null}]}"#
        try Data(body.utf8).write(to: dir.appendingPathComponent("\(stem).json"))
    }

    func testAModFileLandsOnItsTabsAccount() async throws {
        let tab = claudeTab(on: UsageRefs.spareID)
        sessions = [tab]
        try writeModFile(named: tab.id.uuidString, percent: 42, readAt: clock.now)
        let svc = service()
        await svc.tick()
        let r = try XCTUnwrap(svc.ledger.latestReading(account: UsageRefs.spareID))
        XCTAssertEqual(r.source, "claude status line")
        XCTAssertEqual(r.worstWindow?.utilization ?? 0, 0.42, accuracy: 1e-9)
        XCTAssertNil(svc.ledger.latestReading(account: UsageRefs.workID))
    }

    func testAModFileNamedByConversationMapsToItsTab() async throws {
        let conversation = UUID()
        sessions = [claudeTab(on: UsageRefs.spareID, conversation: conversation)]
        try writeModFile(named: conversation.uuidString.lowercased(), percent: 10, readAt: clock.now)
        let svc = service()
        await svc.tick()
        XCTAssertNotNil(svc.ledger.latestReading(account: UsageRefs.spareID),
                        "without FLIGHT_DECK_SESSION_ID the mod names the file by claude's session id")
    }

    func testAModFileForNoKnownTabIsIgnored() async throws {
        try writeModFile(named: UUID().uuidString, percent: 99, readAt: clock.now)
        let svc = service()
        await svc.tick()
        XCTAssertNil(svc.ledger.latestReading(account: UsageRefs.workID))
        XCTAssertNil(svc.ledger.latestReading(account: UsageRefs.spareID))
    }

    func testCodexIsPolledAtMostEveryTwoMinutesWhileItHasATab() async throws {
        sessions = [Session(title: "c", workingDirectory: "/p", agent: .codex, accountID: UsageRefs.codexID)]
        codexResult = try UsageFixtures.object("codex-rate-limits-read")
        let svc = service()
        await svc.tick()
        XCTAssertEqual(codexReads, 1)
        XCTAssertEqual(svc.ledger.latestReading(account: UsageRefs.codexID)?.worstWindow?.utilization ?? 0, 0.88, accuracy: 1e-9)
        clock.advance(60); await svc.tick()
        XCTAssertEqual(codexReads, 1)
        clock.advance(61); await svc.tick()
        XCTAssertEqual(codexReads, 2)
    }

    func testNoCodexTabMeansNoPoll() async {
        let svc = service()
        await svc.tick()
        XCTAssertEqual(codexReads, 0)
    }

    func testAFailedCodexReadIsAVisibleSourceErrorAndNoServerIsNot() async {
        sessions = [Session(title: "c", workingDirectory: "/p", agent: .codex, accountID: UsageRefs.codexID)]
        let svc = service()
        await svc.tick()
        XCTAssertNil(svc.ledger.sourceError(account: UsageRefs.codexID), "no app-server running is normal, not an error")
        codexError = CodexRPCError.transportClosed
        clock.advance(121); await svc.tick()
        XCTAssertTrue(svc.ledger.sourceError(account: UsageRefs.codexID)?.hasPrefix("Codex app-server:") ?? false)
    }

    func testAPushedUpdateMergesForItsAccount() throws {
        let svc = service()
        svc.ingestCodexNotification(account: UsageRefs.codexID, method: "account/rateLimits/updated",
                                    params: try UsageFixtures.object("codex-rate-limits-updated"))
        XCTAssertEqual(svc.ledger.latestReading(account: UsageRefs.codexID)?.worstWindow?.utilization ?? 0, 0.96, accuracy: 1e-9)
        svc.ingestCodexNotification(account: UsageRefs.codexID, method: "thread/started", params: [:])
        XCTAssertEqual(svc.ledger.latestReading(account: UsageRefs.codexID)?.source, "codex app-server")
    }

    func testARateLimitAPIErrorRefusesTheAccountOncePerOccurrence() async throws {
        let tab = claudeTab(on: UsageRefs.workID)
        sessions = [tab]
        apiErrors = [tab.id: SessionAPIError(status: 429, kind: "rate_limit")]
        let svc = service()
        await svc.tick()
        let first = try XCTUnwrap(svc.ledger.rejection(account: UsageRefs.workID))
        clock.advance(30); await svc.tick()
        XCTAssertEqual(svc.ledger.rejection(account: UsageRefs.workID)?.at, first.at, "a standing error is one refusal, not one per tick")
    }

    func testAnOverloadedAPIIsNotThisAccountsLimit() async {
        let tab = claudeTab(on: UsageRefs.workID)
        sessions = [tab]
        apiErrors = [tab.id: SessionAPIError(status: 529, kind: "overloaded")]
        let svc = service()
        await svc.tick()
        XCTAssertNil(svc.ledger.rejection(account: UsageRefs.workID))
    }

    func testHeadlessSeatsMeterTheBuiltInClaudeAccount() async {
        var a = SeatActivity(agent: .claude, startedAt: Date(timeIntervalSince1970: 0))
        a.rateLimitWindows = [UsageWindow(name: "five_hour", utilization: 0.3, resetsAt: nil)]
        a.rateLimitStatus = "allowed"
        a.lastEventAt = clock.now
        seats = [a]
        let svc = service()
        await svc.tick()
        XCTAssertEqual(svc.ledger.latestReading(account: UsageRefs.workID)?.source, "claude headless")
    }

    /// Unify brief R9: a seat that billed the project's account (`accountID`) meters THAT
    /// account, not the built-in one (`Work` here); one whose account is gone credits nobody.
    func testHeadlessSeatsMeterTheAccountTheyBilled() async {
        var billed = SeatActivity(agent: .claude, startedAt: Date(timeIntervalSince1970: 0), accountID: UsageRefs.spareID)
        billed.rateLimitWindows = [UsageWindow(name: "five_hour", utilization: 0.6, resetsAt: nil)]
        billed.rateLimitStatus = "allowed"
        billed.lastEventAt = clock.now
        var orphan = SeatActivity(agent: .claude, startedAt: Date(timeIntervalSince1970: 1), accountID: UUID())
        orphan.rateLimitWindows = [UsageWindow(name: "five_hour", utilization: 0.9, resetsAt: nil)]
        orphan.lastEventAt = clock.now
        seats = [billed, orphan]
        let svc = service()
        await svc.tick()
        XCTAssertEqual(svc.ledger.latestReading(account: UsageRefs.spareID)?.windows.first?.utilization, 0.6)
        XCTAssertNil(svc.ledger.latestReading(account: UsageRefs.workID), "the built-in account billed nothing")
    }

    // MARK: - Planning seats of every agent (round 2, item 10)

    private func account(_ agent: AgentID, _ name: String) throws -> AgentAccount {
        let home = dir.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let made = AgentAccount(agent: agent, displayName: name, home: home)
        accounts.append(made)
        return made
    }

    /// `codex exec --json` carries no rate limits; the rollout codex writes in the seat's own
    /// CODEX_HOME does. The seat's thread id finds it, under the date the seat started.
    func testACodexSeatMetersTheAccountItBilledFromItsRollout() async throws {
        let billed = try account(.codex, "codex-work")
        let day = Calendar.current.dateComponents([.year, .month, .day], from: clock.now)
        let folder = billed.home.appendingPathComponent(String(format: "sessions/%04d/%02d/%02d", day.year!, day.month!, day.day!))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let line = #"{"timestamp":"2026-10-04T17:59:00.000Z","type":"event_msg","payload":{"type":"token_count","info":null,"rate_limits":{"limit_id":"codex","primary":{"used_percent":7.0,"window_minutes":300,"resets_at":1791567291},"secondary":{"used_percent":41.0,"window_minutes":10080,"resets_at":1792017101},"rate_limit_reached_type":null}}}"#
        try Data((line + "\n").utf8).write(to: folder.appendingPathComponent("rollout-2026-10-04T13-59-00-thread-1.jsonl"))
        var seat = SeatActivity(agent: .codex, startedAt: clock.now, accountID: billed.id)
        seat.conversationID = "thread-1"
        seat.lastEventAt = clock.now
        seats = [seat]
        let svc = service()
        await svc.tick()
        let reading = try XCTUnwrap(svc.ledger.latestReading(account: billed.id))
        XCTAssertEqual(reading.source, "codex rollout")
        XCTAssertEqual(reading.worstWindow?.utilization ?? 0, 0.41, accuracy: 1e-9)
        XCTAssertNil(svc.ledger.latestReading(account: UsageRefs.codexID), "the built-in codex login billed nothing")
    }

    /// A grok or gemini seat's stream has no quota numbers, but its refusal does say the limit
    /// was hit: that refuses the account it billed, once per seat.
    func testANonClaudeSeatStoppedByItsLimitRefusesTheAccountItBilled() async throws {
        let billed = try account(.grok, "grok-work")
        var seat = SeatActivity(agent: .grok, startedAt: clock.now, accountID: billed.id)
        seat.error = "You hit your weekly limit."
        seat.lastEventAt = clock.now
        var failed = SeatActivity(agent: .grok, startedAt: clock.now.addingTimeInterval(1), accountID: UsageRefs.spareID)
        failed.error = "exited 1"
        seats = [seat, failed]
        let svc = service()
        await svc.tick()
        XCTAssertEqual(svc.ledger.rejection(account: billed.id)?.source, "Grok headless")
        XCTAssertNil(svc.ledger.rejection(account: UsageRefs.spareID), "an error that is not a limit refuses nothing")
    }

    /// Headless grok writes no billing line (grok 1.0.30, probed 2026-10-09), but the home it ran
    /// in may hold one from that account's TUI: a grok seat meters its account from it.
    func testAGrokSeatMetersTheAccountItBilledFromItsHomesBillingLine() async throws {
        let billed = try account(.grok, "grok-home")
        let logs = billed.home.appendingPathComponent("logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let line = #"{"ts":"2026-10-04T17:00:00.000Z","msg":"billing: fetched credits config","ctx":{"config":{"creditUsagePercent":12.0,"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","start":"2026-10-01T00:00:00Z","end":"2026-10-08T00:00:00Z"}}}}"#
        try Data((line + "\n").utf8).write(to: logs.appendingPathComponent("unified.jsonl"))
        seats = [SeatActivity(agent: .grok, startedAt: clock.now, accountID: billed.id)]
        let svc = service()
        await svc.tick()
        XCTAssertEqual(svc.ledger.latestReading(account: billed.id)?.source, "grok billing log")
    }

    /// agy's `/usage` is polled while a gemini seat runs, as it is while a gemini tab is open,
    /// and credited to the account the seat billed. A finished seat starts no poll.
    func testARunningGeminiSeatPollsAgyForTheAccountItBilled() async throws {
        let billed = try account(.gemini, "gemini")
        let usage = #"{"command":{"name":"usage","data":{"groups":[{"name":"Gemini Models","buckets":[{"id":"gemini-5h","remaining_fraction":0.75,"reset_time":"2026-10-04T20:00:00Z"}]}]}}}"#
        let polls = UsagePollCounter()
        var done = SeatActivity(agent: .gemini, startedAt: clock.now, accountID: billed.id)
        done.finished = true
        seats = [done]
        let svc = service(geminiUsage: { polls.bump(); return Data(usage.utf8) })
        await svc.tick()
        XCTAssertEqual(polls.count, 0)
        seats = [SeatActivity(agent: .gemini, startedAt: clock.now, accountID: billed.id)]
        await svc.tick()
        XCTAssertEqual(polls.count, 1)
        XCTAssertEqual(svc.ledger.latestReading(account: billed.id)?.worstWindow?.utilization ?? 0, 0.25, accuracy: 1e-9)
    }

    // Behavior changed on purpose (final review): the notice is per ACCOUNT per crossing, and a
    // reading already over hard on the first tick is stale news (mod files outlive a relaunch),
    // so the crossing must be observed while running.
    func testAManualTabIsToldOncePerCrossing() async {
        let tab = claudeTab(on: UsageRefs.workID)
        sessions = [tab]
        let svc = service()
        await svc.tick()
        svc.ingest(UsageRefs.reading(UsageRefs.work, 0.97, at: clock.now))
        await svc.tick(); await svc.tick()
        XCTAssertEqual(notifier.notes.count, 1)
        XCTAssertEqual(notifier.notes.first?.session, tab.id)
        clock.advance(10); svc.ingest(UsageRefs.reading(UsageRefs.work, 0.10, at: clock.now)); await svc.tick()
        clock.advance(10); svc.ingest(UsageRefs.reading(UsageRefs.work, 0.98, at: clock.now)); await svc.tick()
        XCTAssertEqual(notifier.notes.count, 2, "a new crossing is news again")
    }

    func testThreeManualTabsOnOneOverHardAccountSendOneNotice() async {
        sessions = [claudeTab(on: UsageRefs.workID), claudeTab(on: UsageRefs.workID), claudeTab(on: UsageRefs.workID)]
        let svc = service()
        await svc.tick()
        svc.ingest(UsageRefs.reading(UsageRefs.work, 0.97, at: clock.now))
        await svc.tick(); await svc.tick()
        XCTAssertEqual(notifier.notes.count, 1)
    }

    func testATabWithoutALiveStatusIsNotCounted() async {
        let dead = claudeTab(on: UsageRefs.workID)
        sessions = [dead]; live = []
        let svc = service()
        await svc.tick()
        svc.ingest(UsageRefs.reading(UsageRefs.work, 0.97, at: clock.now))
        await svc.tick()
        XCTAssertEqual(notifier.notes, [])
    }

    func testAnAccountAlreadyOverHardOnTheFirstTickIsNotAnnouncedUntilItCrossesAgain() async {
        sessions = [claudeTab(on: UsageRefs.workID)]
        let svc = service()
        svc.ingest(UsageRefs.reading(UsageRefs.work, 0.97, at: clock.now))
        await svc.tick(); await svc.tick()
        XCTAssertEqual(notifier.notes, [], "a stale on-disk reading at launch is not a crossing")
        clock.advance(10); svc.ingest(UsageRefs.reading(UsageRefs.work, 0.10, at: clock.now)); await svc.tick()
        clock.advance(10); svc.ingest(UsageRefs.reading(UsageRefs.work, 0.98, at: clock.now)); await svc.tick()
        XCTAssertEqual(notifier.notes.count, 1)
    }

    func testASwarmTabIsNotNotifiedTheDriverHandlesIt() async {
        let tab = claudeTab(on: UsageRefs.workID)
        sessions = [tab]; swarm = [tab.id]
        let svc = service()
        svc.ingest(UsageRefs.reading(UsageRefs.work, 0.97, at: clock.now))
        await svc.tick()
        XCTAssertEqual(notifier.notes, [])
    }

    func testFifteenSilentMinutesFromTheModIsAVisibleError() async throws {
        let tab = claudeTab(on: UsageRefs.spareID)
        sessions = [tab]
        let svc = service()
        await svc.tick()
        clock.advance(14 * 60); await svc.tick()
        XCTAssertNil(svc.ledger.sourceError(account: UsageRefs.spareID))
        clock.advance(60); await svc.tick()
        XCTAssertEqual(svc.ledger.sourceError(account: UsageRefs.spareID), UsageService.statusLineSilenceMessage)
        try writeModFile(named: tab.id.uuidString, percent: 5, readAt: clock.now)
        await svc.tick()
        XCTAssertNil(svc.ledger.sourceError(account: UsageRefs.spareID))
    }

    func testATapDeliversOnlyItsAccountsReadings() async {
        let svc = service()
        let tap = svc.tap(agent: .claude, account: nil)
        XCTAssertEqual(tap.accountID, UsageRefs.workID, "nil is the built-in account, resolved")
        svc.ingest(UsageRefs.reading(UsageRefs.spare, 0.5, at: clock.now))
        svc.ingest(UsageRefs.reading(UsageRefs.work, 0.6, at: clock.now))
        var it = tap.readings.makeAsyncIterator()
        let r = await it.next()
        XCTAssertEqual(r?.account, UsageRefs.work)
    }

    func testConsumeReadsAnyMeterSource() async {
        let svc = service()
        let fake = FakeUsageMeterSource()
        let task = svc.consume(fake)
        fake.send(UsageRefs.reading(UsageRefs.spare, 0.25, at: clock.now)); fake.finish()
        await task.value
        XCTAssertEqual(svc.ledger.latestReading(account: UsageRefs.spareID)?.worstWindow?.utilization, 0.25)
    }

    func testReconfigurePicksUpStoredPools() throws {
        let svc = service()
        XCTAssertNil(svc.ledger.pool("pool-night001"))
        var list = AccountList(entries: accounts.map(AccountEntry.account))
        try list.addPool(AccountPool(id: "pool-night001", label: "Night", agent: .claude, members: [accounts[1]]))
        accountList = list
        svc.reconfigure()
        XCTAssertEqual(svc.ledger.pool("pool-night001")?.accounts, [UsageRefs.spareID])
    }

    func testCapabilitiesNowAnswerMeterAndTranscript() throws {
        XCTAssertNotNil(ClaudeRoutingCapabilities().usageMeterSource(account: nil).value)
        XCTAssertNotNil(CodexRoutingCapabilities().usageMeterSource(account: nil).value)
        let rollout = dir.appendingPathComponent("rollout.jsonl")
        try Data().write(to: rollout)
        let codexTab = Session(title: "c", workingDirectory: "/p", agent: .codex, transcriptPath: rollout.path)
        XCTAssertEqual(CodexRoutingCapabilities().transcriptPointer(for: codexTab).value?.locator, .path(rollout.path))
        XCTAssertNil(CodexRoutingCapabilities().transcriptPointer(for: Session(title: "c", workingDirectory: "/p", agent: .codex)).value)
    }

    // Ruling M4: one stuck app-server must not freeze the tick.
    func testAStuckCodexServerCannotFreezeTheTick() async throws {
        let tab = claudeTab(on: UsageRefs.spareID)
        sessions = [tab, Session(title: "c", workingDirectory: "/p", agent: .codex, accountID: UsageRefs.codexID)]
        codexHangs = true
        try writeModFile(named: tab.id.uuidString, percent: 42, readAt: clock.now)
        let svc = service(codexReadTimeout: 0.05)
        let started = Date()
        await svc.tick()
        XCTAssertLessThan(Date().timeIntervalSince(started), 5, "tick returned instead of waiting on the read")
        XCTAssertTrue(svc.ledger.sourceError(account: UsageRefs.codexID)?.hasPrefix("Codex app-server did not answer") ?? false)
        XCTAssertNotNil(svc.ledger.latestReading(account: UsageRefs.spareID), "other sources still land in the same tick")
        XCTAssertEqual(codexReads, 1)
        clock.advance(121); await svc.tick()
        XCTAssertEqual(codexReads, 1, "the first read has not returned, so no second one is started")
    }

    // Ruling M7: a predicate set before attach survives the environment swap.
    func testTheSwarmPredicateSurvivesAnEnvironmentSwap() async {
        let tab = claudeTab(on: UsageRefs.workID)
        sessions = [tab]
        let svc = service()
        svc.setSwarmPredicate { [tab] in $0 == tab.id }
        var replacement = UsageEnvironment.empty
        replacement.usageDirectory = dir
        replacement.sessions = { [unowned self] in self.sessions }
        replacement.accounts = { [unowned self] in self.accounts }
        replacement.resolvedAccountID = { _, stored in stored ?? UsageRefs.workID }
        replacement.notifier = { [unowned self] in self.notifier }
        svc.replaceEnvironment(replacement)
        svc.ingest(UsageRefs.reading(UsageRefs.work, 0.97, at: clock.now))
        await svc.tick()
        XCTAssertEqual(notifier.notes, [])
    }

    // Ruling m4: the pointer comes from the session's agent, not from the shared registry.
    func testTranscriptPointerForACodexSessionNeedsNoSingleton() throws {
        let rollout = dir.appendingPathComponent("r.jsonl")
        try Data().write(to: rollout)
        let tab = Session(title: "c", workingDirectory: "/p", agent: .codex, transcriptPath: rollout.path)
        sessions = [tab]
        let svc = service()
        XCTAssertEqual(svc.transcriptPointer(for: SessionRef(id: tab.id, agentName: nil))?.locator, .path(rollout.path))
    }
}

final class UsagePollCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func bump() { lock.withLock { value += 1 } }
    var count: Int { lock.withLock { value } }
}
