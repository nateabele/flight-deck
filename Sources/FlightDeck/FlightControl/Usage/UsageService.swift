import Combine
import FleetKit
import Foundation
import IntakeKit

/// What `UsageService` reads from the rest of the app. Closures, so its tests drive it from
/// literals instead of a live store; `@MainActor` because every real answer comes from the
/// store or the preferences, which are.
struct UsageEnvironment {
    var sessions: @MainActor () -> [Session]
    var apiErrors: @MainActor () -> [UUID: SessionAPIError]
    /// Every account, tombstones included: a removed account's running tab still reports, and
    /// its readings must land under its own id.
    var accounts: @MainActor () -> [AgentAccount]
    var resolvedAccountID: @MainActor (AgentID, UUID?) -> UUID?
    /// The pools in force — the Accounts list's (`PreferencesStore.effectivePools`).
    var pools: @MainActor () -> [CapacityPool]
    var usageDirectory: URL
    /// The account's codex `account/rateLimits/read`, or nil when no app-server runs for it.
    var codexRead: @MainActor (UUID?) async throws -> [String: Any]?
    var seatActivities: @MainActor () -> [SeatActivity]
    var notifier: @MainActor () -> Notifying?
    /// Swarm tabs are the hand-off driver's; only manual tabs get the one-time notice. The real
    /// answer is `setSwarmPredicate` (installed by `FlightControlComposition`), which wins over
    /// this; without it every tab is manual.
    var isSwarmSession: @MainActor (UUID) -> Bool
    /// Whether the tab's agent is running (the store has a status for it). A tab whose agent has
    /// exited is still in the sidebar; telling the user about its account's limit is noise.
    var isLive: @MainActor (UUID) -> Bool = { _ in true }
    /// agy's `/usage` answer as raw JSON, or nil (`GeminiUsageSource.read`). Run off the main
    /// actor by the caller; defaulted to nothing so a test environment never spawns agy.
    var geminiUsage: @Sendable () async -> Data? = { nil }

    static var empty: UsageEnvironment {
        UsageEnvironment(sessions: { [] }, apiErrors: { [:] }, accounts: { [] },
                         resolvedAccountID: { _, stored in stored }, pools: { [] },
                         usageDirectory: ClaudePluginLocation.usageDirectory, codexRead: { _ in nil },
                         seatActivities: { [] }, notifier: { nil }, isSwarmSession: { _ in false })
    }

    @MainActor
    static func live(store: SessionStore, preferences: PreferencesStore) -> UsageEnvironment {
        UsageEnvironment(
            sessions: { [weak store] in store?.repos.flatMap(\.sessions) ?? [] },
            apiErrors: { [weak store] in store?.apiErrors ?? [:] },
            accounts: { [weak preferences] in preferences?.preferences.accounts ?? [] },
            resolvedAccountID: { [weak preferences] agent, stored in
                preferences?.resolvedAccountID(for: agent, in: stored) ?? stored
            },
            pools: { [weak preferences] in preferences?.effectivePools ?? [] },
            usageDirectory: ClaudePluginLocation.usageDirectory,
            codexRead: { [weak store] account in try await store?.codexRateLimitsRead(account: account) },
            // `intakeService` is lazy, but reading it here is safe: `collapsedStatus` already
            // builds it unconditionally, so this adds no side effect that was not already there.
            seatActivities: { [weak store] in
                guard let intake = store?.intakeService else { return [] }
                return intake.seatActivities.values.flatMap(\.values) + Array(intake.triageActivities.values)
            },
            notifier: { [weak store] in store?.notifier },
            isSwarmSession: { _ in false },
            isLive: { [weak store] in store?.statuses[$0] != nil },
            geminiUsage: {
                await Task.detached(priority: .utility) {
                    GeminiUsageSource.read(path: LoginShellPath.repairing()["PATH"])
                }.value
            })
    }
}

/// The contract's per-account `UsageMeterSource` (L3-0), served by `usageMeterSource(account:)`.
/// A view onto `UsageService`'s funnel rather than a second meter: everything an adapter could
/// report already arrives there.
final class UsageMeterTap: UsageMeterSource, @unchecked Sendable {
    let accountID: UUID?
    let readings: AsyncStream<UsageReading>
    private let continuation: AsyncStream<UsageReading>.Continuation

    init(accountID: UUID?) {
        self.accountID = accountID
        (readings, continuation) = AsyncStream.makeStream(of: UsageReading.self, bufferingPolicy: .bufferingNewest(16))
    }

    func send(_ reading: UsageReading) { continuation.yield(reading) }
    func finish() { continuation.finish() }
}

/// Funnels every meter into `CapacityLedger` and keeps the account states current (L3-U §3).
///
/// One per app (`shared`), attached once to the store and preferences from `AppDelegate`'s
/// store-ready hops. It ticks every 30 s — usage windows move over hours, so a faster beat only
/// spends the main actor — and each tick it scans the status line's usage files, folds headless seats, turns
/// rate-limit API errors into refusals, polls codex at most every 120 s per account with a live
/// codex tab, flags a silent status line, and tells manual tabs once when their account crosses hard.
@MainActor
final class UsageService: ObservableObject {
    static let shared = UsageService()

    static let tickInterval: Duration = .seconds(30)
    static let codexPollInterval: TimeInterval = 120
    /// A stuck app-server must not hold the tick: `CodexRPC.request` has no timeout of its own.
    static let defaultCodexReadTimeout: TimeInterval = 20
    static let statusLineSilenceGrace: TimeInterval = 15 * 60
    static let fileRetention: TimeInterval = 7 * 24 * 3600
    /// The status line is the only claude meter for interactive tabs, and claude can skip it
    /// without telling anyone: an untrusted folder, `disableAllHooks`, or managed settings that
    /// set their own. A status line also runs only once claude has answered; a tab that never
    /// sent a prompt has nothing to report, so this waits 15 minutes before it accuses anything.
    static let statusLineSilenceMessage = "No usage reading from Claude's status line in this account's tabs for 15 minutes. Flight Deck's status line may not have run (untrusted folder, disableAllHooks, or managed settings), or no tab has had a reply yet."

    let ledger: CapacityLedger
    /// Bumped on every change and every tick: freshness and window resets move with the clock
    /// even when no new reading arrives, so the meters must redraw anyway.
    @Published private(set) var revision = 0
    private(set) var isAttached = false
    private(set) var environment: UsageEnvironment
    private let now: () -> Date
    private let codexReadTimeout: TimeInterval
    /// Kept apart from `environment` so `attach` replacing the environment cannot drop a
    /// predicate L3-S installed before it.
    private var swarmPredicate: (@MainActor (UUID) -> Bool)?
    private var codexReadsInFlight: Set<UUID> = []

    private var usageFiles: ClaudeUsageFileSource
    private let headless = HeadlessClaudeUsageSource()
    private var codexSources: [UUID: CodexRateLimitSource] = [:]
    private var lastCodexPoll: [UUID: Date] = [:]
    private var lastGrokBilling: [UUID: Date] = [:]
    private var lastGeminiPoll: Date?
    private var geminiReadInFlight = false
    /// Seats already turned into a refusal or a rollout reading, so a seat re-read every tick
    /// (its `activity.json` stays put while the intake shapes) reports once, not every 30 s.
    private var seatRejectionsSeen: Set<String> = []
    private var codexRolloutsSeen: Set<String> = []
    private struct WeakTap { weak var tap: UsageMeterTap? }
    private var taps: [WeakTap] = []
    private var firstSeen: [UUID: Date] = [:]
    private var reported: Set<UUID> = []
    private var rejectedTabs: Set<UUID> = []
    /// Accounts already announced for the current crossing; keyed by account, not tab, so eight
    /// tabs on one account make one notice.
    private var notifiedOverHard: Set<UUID> = []
    private var noticeSeeded = false
    private var loop: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []

    init(environment: UsageEnvironment = .empty, ledger: CapacityLedger = CapacityLedger(), now: @escaping () -> Date = Date.init,
         codexReadTimeout: TimeInterval = UsageService.defaultCodexReadTimeout) {
        self.environment = environment
        self.codexReadTimeout = codexReadTimeout
        self.ledger = ledger
        self.now = now
        usageFiles = ClaudeUsageFileSource(directory: environment.usageDirectory)
        reconfigure()
    }

    /// The real `HandoffPlanner`, which `FlightControlGraph` gives the `HandoffDriver`. The
    /// reservation list is the driver host's job (it asks Agent Mail just before the prompt),
    /// so the planner's is empty. The planner must be called on the main actor (the hand-off
    /// driver is `@MainActor`): its transcript closure asserts it with `assumeIsolated`.
    lazy var planner = LedgerHandoffPlanner(
        reader: ledger,
        transcript: { [weak self] ref in MainActor.assumeIsolated { self?.transcriptPointer(for: ref) } },
        reservedFiles: { _ in [] })

    func attach(store: SessionStore, preferences: PreferencesStore) {
        guard !isAttached else { return }
        isAttached = true
        replaceEnvironment(.live(store: store, preferences: preferences))
        usageFiles.prune(olderThan: Self.fileRetention, now: now())
        store.onCodexNotification = { [weak self] account, method, params in
            self?.ingestCodexNotification(account: account, method: method, params: params)
        }
        // `@Published` emits in `willSet`, so the new preferences are read one hop later.
        preferences.$preferences
            .sink { [weak self] _ in Task { @MainActor in self?.reconfigure() } }
            .store(in: &cancellables)
        reconfigure()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(for: Self.tickInterval)
            }
        }
    }

    /// What `attach` does to swap in the live environment; separate so a test can do the same
    /// without a real store.
    func replaceEnvironment(_ new: UsageEnvironment) {
        environment = new
        usageFiles = ClaudeUsageFileSource(directory: new.usageDirectory)
    }

    /// "Is this tab a swarm agent?", answered from the swarm's records by
    /// `FlightControlComposition`. Without it every tab is manual: it gets the one-time notice
    /// and is never handed off.
    func setSwarmPredicate(_ isSwarm: @escaping @MainActor (UUID) -> Bool) {
        swarmPredicate = isSwarm
    }

    func reconfigure() {
        let accounts = environment.accounts()
        ledger.configure(pools: environment.pools(),
                         accounts: accounts.map(CapacityPreferences.accountRef))
        revision += 1
    }

    func ingest(_ reading: UsageReading) {
        ledger.ingest(reading)
        taps.removeAll { $0.tap == nil }
        for box in taps where box.tap?.accountID == reading.account.id { box.tap?.send(reading) }
        revision += 1
    }

    /// How a source that is a stream (the OpenCode adapter's, say) joins the funnel.
    @discardableResult
    func consume(_ source: any UsageMeterSource) -> Task<Void, Never> {
        Task { [weak self] in
            for await reading in source.readings { self?.ingest(reading) }
        }
    }

    func tick() async {
        let t = now()
        let sessions = environment.sessions()
        let seats = environment.seatActivities()
        for s in sessions where firstSeen[s.id] == nil { firstSeen[s.id] = t }
        ingestUsageFiles(sessions)
        ingestHeadlessSeats(seats)
        ingestAPIErrors(sessions, at: t)
        await pollCodex(sessions, at: t)
        ingestGrokBilling(sessions, seats: seats)
        await pollGemini(sessions, seats: seats, at: t)
        flagSilentStatusLine(sessions, at: t)
        noticeManualTabs(sessions)
        revision += 1
    }

    func ingestCodexNotification(account: UUID?, method: String, params: [String: Any]) {
        guard method == "account/rateLimits/updated", let id = account ?? environment.resolvedAccountID(.codex, nil),
              let ref = ref(forAccount: id) else { return }
        let source = codexSource(id)
        source.applyUpdate(params)
        if let reading = source.reading(account: ref, at: now()) { ingest(reading) }
    }

    func tap(agent: AgentID, account: AgentAccount?) -> UsageMeterTap {
        let id = account?.id ?? environment.resolvedAccountID(agent, nil)
        let tap = UsageMeterTap(accountID: id)
        taps.append(WeakTap(tap: tap))
        if let id, let latest = ledger.latestReading(account: id) { tap.send(latest) }
        return tap
    }

    func accountRef(for session: Session) -> AccountRef? {
        environment.resolvedAccountID(session.agent, session.accountID).flatMap(ref(forAccount:))
    }

    /// The grok home a tab runs in: its account's, else the built-in `~/.grok`.
    func grokHome(for session: Session) -> URL {
        let id = environment.resolvedAccountID(.grok, session.accountID)
        return environment.accounts().first { $0.id == id }?.home ?? AgentID.grok.builtInHome
    }

    /// The account's `projects/` directory — the root claude writes this tab's transcript under.
    func claudeProjectsRoot(for session: Session) -> URL {
        let id = environment.resolvedAccountID(.claude, session.accountID)
        let home = environment.accounts().first { $0.id == id }?.home ?? AgentID.claude.builtInHome
        return home.appendingPathComponent("projects", isDirectory: true)
    }

    func transcriptPointer(for ref: SessionRef) -> TranscriptPointer? {
        guard let session = environment.sessions().first(where: { $0.id == ref.id }) else { return nil }
        // Computed from the agent directly: going through the capability registry would read
        // `UsageService.shared`, not this instance.
        switch session.agent {
        case .claude: return TranscriptPointers.claude(session: session, projectsRoot: claudeProjectsRoot(for: session))
        case .codex: return TranscriptPointers.codex(session: session)
        case .grok: return TranscriptPointers.grok(session: session, home: grokHome(for: session))
        case .gemini: return TranscriptPointers.gemini(session: session)
        default: return nil
        }
    }

    /// Over hard in any hosted pool that holds it. The strictest pool decides, so a manual tab is
    /// warned at the earliest threshold anyone configured for its account.
    func isOverHard(account id: UUID) -> Bool {
        ledger.allPools.filter { $0.kind == .hosted && $0.accounts.contains(id) }.contains { pool in
            ledger.headroom(pool: pool.id).contains { $0.account.id == id && $0.state == .overHard }
        }
    }

    // MARK: - One tick

    private func ref(forAccount id: UUID) -> AccountRef? {
        environment.accounts().first { $0.id == id }.map(CapacityPreferences.accountRef)
    }

    private func codexSource(_ id: UUID) -> CodexRateLimitSource {
        if let existing = codexSources[id] { return existing }
        let made = CodexRateLimitSource()
        codexSources[id] = made
        return made
    }

    /// grok's weekly meter, from the billing line its own log carries (`GrokBillingSource`):
    /// one read per account with a grok tab, ingested only when the line is newer than the last
    /// one taken, so a quiet account is not re-stamped fresh every tick.
    ///
    /// A grok planning seat's account is read the same way: headless `grok -p` writes NO billing
    /// line of its own (grok 1.0.30, probed 2026-10-09 — only the TUI fetches the credits
    /// config), so a seat meters its account only from the line that account's TUI last left in
    /// the same home. That is still the right account's quota, just as fresh as its last TUI turn.
    private func ingestGrokBilling(_ sessions: [Session], seats: [SeatActivity] = []) {
        let ids = Set(sessions.filter { $0.agent == .grok }.compactMap { environment.resolvedAccountID(.grok, $0.accountID) })
            .union(seats.filter { $0.agent == .grok }.compactMap { seatAccount($0)?.id })
        for id in ids {
            guard let ref = ref(forAccount: id),
                  let home = environment.accounts().first(where: { $0.id == id })?.home,
                  let tail = GrokBillingSource.readTail(home: home),
                  let found = GrokBillingSource.windows(inLogTail: tail)
            else { continue }
            let readAt = found.readAt ?? now()
            guard lastGrokBilling[id] != readAt else { continue }
            lastGrokBilling[id] = readAt
            ingest(UsageReading(account: ref, windows: found.windows, readAt: readAt,
                                source: "grok billing log", hardRejection: false))
        }
    }

    private func ingestUsageFiles(_ sessions: [Session]) {
        for (stem, file) in usageFiles.scan() {
            guard let tab = sessions.first(where: { $0.agent == .claude && ($0.id == stem || $0.pinnedConversationID == stem) }),
                  let ref = accountRef(for: tab) else { continue }
            reported.insert(tab.id)
            ingest(UsageReading(account: ref, windows: file.windows, readAt: file.readAt, source: "claude status line", hardRejection: false))
        }
    }

    /// A headless seat bills the account the app resolved for its project when its runner (or
    /// triage turn) started, recorded on the seat as `accountID` (unify brief R9) — a Work-pool
    /// seat's rate-limit windows are Work's, and crediting them to the built-in login would let
    /// the pool keep leasing an account that is in fact exhausted. A seat with no id (an agent
    /// with no account record, or a runner from before R9) ran in the built-in home, so it is
    /// credited there, as every seat once was.
    ///
    /// Every agent's seat feeds the meter it can (round 2, item 10), each credited to the account
    /// the seat billed:
    /// - claude: the stream's `rate_limit_event`s (`HeadlessClaudeUsageSource`);
    /// - codex: the rollout the seat wrote in its CODEX_HOME (`ingestCodexSeatRollouts`);
    /// - grok: its home's billing log line (`ingestGrokBilling`);
    /// - gemini: agy's `/usage`, polled while the seat runs (`pollGemini`);
    /// - every non-claude agent: a seat that ended on its vendor's limit refuses its account.
    private func ingestHeadlessSeats(_ seats: [SeatActivity]) {
        for reading in headless.readings(from: seats, account: { [self] in seatAccount($0) }) { ingest(reading) }
        ingestSeatRejections(seats)
        ingestCodexSeatRollouts(seats)
    }

    /// The account a seat billed. An id that no longer names an account (purged since) credits
    /// nobody: its numbers are not the built-in login's either. No id is the agent's built-in.
    private func seatAccount(_ seat: SeatActivity) -> AccountRef? {
        if let id = seat.accountID { return ref(forAccount: id) }
        return environment.resolvedAccountID(seat.agent, nil).flatMap(ref(forAccount:))
    }

    /// grok and agy streams carry no quota numbers at all, and codex's only in its rollout; what
    /// every one of them does carry is the refusal itself ("You hit your weekly limit.",
    /// "usage limit reached", a 429). Classified by the shared vocabulary every profile uses, so
    /// an overloaded API is never read as this account's limit. Claude is left to its own
    /// `rate_limit_event`, which says the same thing with a reset time.
    private func ingestSeatRejections(_ seats: [SeatActivity]) {
        for seat in seats where seat.agent != .claude {
            guard let error = seat.error, AgentErrorVocabulary.classify(text: error) == .rateLimited,
                  let account = seatAccount(seat) else { continue }
            let key = "\(seat.agent.rawValue)|\(seat.startedAt.timeIntervalSince1970)"
            guard seatRejectionsSeen.insert(key).inserted else { continue }
            ingest(UsageReading(account: account, windows: [], readAt: seat.lastEventAt ?? seat.startedAt,
                                source: "\(seat.agent.displayName) headless", hardRejection: true))
        }
        if seatRejectionsSeen.count > 4_096 { seatRejectionsSeen.removeAll() }
    }

    /// A codex seat's rate limits, from the rollout it wrote: `codex exec --json` has none on
    /// stdout (codex-cli 0.160.0, probed 2026-10-09). Read once per seat event; a rollout not
    /// written yet is tried again next tick, until the seat finishes.
    private func ingestCodexSeatRollouts(_ seats: [SeatActivity]) {
        for seat in seats where seat.agent == .codex {
            guard let thread = seat.conversationID, let account = seatAccount(seat) else { continue }
            let at = seat.lastEventAt ?? seat.startedAt
            let key = "\(thread)|\(at.timeIntervalSince1970)"
            guard !codexRolloutsSeen.contains(key) else { continue }
            let home = environment.accounts().first { $0.id == account.id }?.home ?? AgentID.codex.builtInHome
            if let url = CodexRolloutFile.find(home: home, thread: thread, near: seat.startedAt),
               let tail = CodexRolloutFile.tail(url),
               let found = CodexRolloutRateLimits.newest(inRolloutTail: tail),
               let reading = CodexRateLimitParser.reading(found.buckets, account: account, readAt: found.readAt ?? at,
                                                          source: "codex rollout") {
                codexRolloutsSeen.insert(key)
                ingest(reading)
            } else if seat.finished {
                codexRolloutsSeen.insert(key)
            }
        }
        if codexRolloutsSeen.count > 4_096 { codexRolloutsSeen.removeAll() }
    }

    private func ingestAPIErrors(_ sessions: [Session], at t: Date) {
        let errors = environment.apiErrors()
        for s in sessions {
            guard let e = errors[s.id], RateLimitClassifier.isRateLimit(status: e.status, kind: e.kind) else {
                rejectedTabs.remove(s.id)
                continue
            }
            // Once per occurrence: a standing error re-reported every tick would push the
            // 15-minute backoff forward forever.
            guard rejectedTabs.insert(s.id).inserted, let ref = accountRef(for: s) else { continue }
            ingest(UsageReading(account: ref, windows: [], readAt: t, source: "\(s.agent.displayName) API error", hardRejection: true))
        }
    }

    private func pollCodex(_ sessions: [Session], at t: Date) async {
        let keys = Set(sessions.filter { $0.agent == .codex }.compactMap { environment.resolvedAccountID(.codex, $0.accountID) })
        for id in keys.sorted(by: { $0.uuidString < $1.uuidString }) {
            if let last = lastCodexPoll[id], t.timeIntervalSince(last) < Self.codexPollInterval { continue }
            lastCodexPoll[id] = t
            guard let ref = ref(forAccount: id) else { continue }
            // At most one read in flight per account: a stuck server must not leak one per poll.
            guard codexReadsInFlight.insert(id).inserted else { continue }
            switch await boundedCodexRead(id) {
            case .result(let result):
                guard let result else { continue }
                let source = codexSource(id)
                source.applyRead(result)
                if let reading = source.reading(account: ref, at: t) { ingest(reading) }
            case .failed(let error):
                // No reading this tick; the ledger keeps a still-fresh one (deviation 16).
                ledger.setSourceError("Codex app-server: \(error)", account: id)
            case .timedOut:
                ledger.setSourceError("Codex app-server did not answer within \(Int(codexReadTimeout)) s", account: id)
            }
        }
    }

    /// agy's quota for the one gemini account (unify brief R5), at most every
    /// `GeminiUsageSource.pollInterval`, and only while a gemini tab exists: each read spawns agy
    /// twice. No reading is not an error worth flagging — agy may simply be signed out, and
    /// `GeminiUsageSource.read` refuses to run `/usage` then rather than open a browser.
    ///
    /// A RUNNING gemini planning seat counts like a tab, credited to the account it billed: agy's
    /// headless stream reports tokens and nothing about quota (agy 1.3.2), so this poll is the
    /// only meter a seat-only gemini account has. A finished seat starts no poll.
    private func pollGemini(_ sessions: [Session], seats: [SeatActivity] = [], at t: Date) async {
        let target = sessions.first(where: { $0.agent == .gemini }).flatMap(accountRef(for:))
            ?? seats.first(where: { $0.agent == .gemini && !$0.finished }).flatMap(seatAccount)
        guard let ref = target, !geminiReadInFlight,
              lastGeminiPoll.map({ t.timeIntervalSince($0) >= GeminiUsageSource.pollInterval }) ?? true
        else { return }
        lastGeminiPoll = t
        geminiReadInFlight = true
        let data = await environment.geminiUsage()
        geminiReadInFlight = false
        guard let data, let windows = GeminiUsageSource.windows(fromUsageJSON: data), !windows.isEmpty else { return }
        ingest(UsageReading(account: ref, windows: windows, readAt: t, source: "agy /usage", hardRejection: false))
    }

    private enum CodexReadOutcome { case result([String: Any]?), failed(Error), timedOut }

    /// Races the read against a timeout with a continuation resumed once, not a task group: a
    /// group waits for every child at scope exit, so a read that never returns would still
    /// block the tick. The read keeps running after a timeout; `codexReadsInFlight` stays set
    /// until it ends, which is what stops the next poll from stacking another on it.
    private func boundedCodexRead(_ id: UUID) async -> CodexReadOutcome {
        let read = environment.codexRead
        let timeout = codexReadTimeout
        return await withCheckedContinuation { continuation in
            let gate = ResumeOnce(continuation)
            Task { @MainActor [weak self] in
                let outcome: CodexReadOutcome
                do { outcome = .result(try await read(id)) } catch { outcome = .failed(error) }
                self?.codexReadsInFlight.remove(id)
                gate.resume(outcome)
            }
            Task {
                try? await Task.sleep(for: .seconds(timeout))
                gate.resume(.timedOut)
            }
        }
    }

    private final class ResumeOnce: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<CodexReadOutcome, Never>?
        init(_ continuation: CheckedContinuation<CodexReadOutcome, Never>) { self.continuation = continuation }
        func resume(_ outcome: CodexReadOutcome) {
            lock.lock(); let c = continuation; continuation = nil; lock.unlock()
            c?.resume(returning: outcome)
        }
    }

    private func flagSilentStatusLine(_ sessions: [Session], at t: Date) {
        var tabsByAccount: [UUID: [Session]] = [:]
        for s in sessions where s.agent == .claude {
            if let id = environment.resolvedAccountID(.claude, s.accountID) { tabsByAccount[id, default: []].append(s) }
        }
        for (id, tabs) in tabsByAccount where ledger.latestReading(account: id) == nil && !tabs.contains(where: { reported.contains($0.id) }) {
            let oldest = tabs.compactMap { firstSeen[$0.id] }.min() ?? t
            if t.timeIntervalSince(oldest) >= Self.statusLineSilenceGrace { ledger.setSourceError(Self.statusLineSilenceMessage, account: id) }
        }
    }

    private func noticeManualTabs(_ sessions: [Session]) {
        let isSwarm = swarmPredicate ?? environment.isSwarmSession
        var manualByAccount: [UUID: (ref: AccountRef, tabs: [Session])] = [:]
        var allAccounts: Set<UUID> = []
        for s in sessions {
            guard let ref = accountRef(for: s), let id = ref.id else { continue }
            allAccounts.insert(id)
            guard !isSwarm(s.id), environment.isLive(s.id) else { continue }
            manualByAccount[id, default: (ref, [])].tabs.append(s)
        }
        // The first tick only records what is already over hard. The usage files persist across a
        // relaunch and the 7-day window can sit above 95 % for days, so a reading found at launch
        // is old news; only a crossing observed while running is announced.
        if !noticeSeeded {
            noticeSeeded = true
            notifiedOverHard = Set(allAccounts.filter(isOverHard(account:)))
            return
        }
        // Re-arm every account that dropped back under hard, even one with no live tab now.
        notifiedOverHard = notifiedOverHard.filter(isOverHard(account:))
        for (id, entry) in manualByAccount.sorted(by: { $0.key.uuidString < $1.key.uuidString })
        where isOverHard(account: id) && notifiedOverHard.insert(id).inserted {
            let first = entry.tabs[0]
            environment.notifier()?.notify(
                sessionID: first.id, title: "\(entry.ref.label) is near its usage limit",
                subtitle: entry.tabs.count == 1 ? first.title : "\(entry.tabs.count) tabs",
                body: "Flight Control does not move your own tabs. This agent may stop until the limit resets.")
        }
    }
}
