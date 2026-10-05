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
    var capacity: @MainActor () -> CapacityPreferences
    var usageDirectory: URL
    /// The account's codex `account/rateLimits/read`, or nil when no app-server runs for it.
    var codexRead: @MainActor (UUID?) async throws -> [String: Any]?
    var seatActivities: @MainActor () -> [SeatActivity]
    var notifier: @MainActor () -> Notifying?
    /// Swarm tabs are the hand-off driver's; only manual tabs get the one-time notice. L3-S
    /// answers this at integration; until then every tab is manual.
    var isSwarmSession: @MainActor (UUID) -> Bool
    /// Whether the tab's agent is running (the store has a status for it). A tab whose agent has
    /// exited is still in the sidebar; telling the user about its account's limit is noise.
    var isLive: @MainActor (UUID) -> Bool = { _ in true }

    static var empty: UsageEnvironment {
        UsageEnvironment(sessions: { [] }, apiErrors: { [:] }, accounts: { [] },
                         resolvedAccountID: { _, stored in stored }, capacity: { CapacityPreferences() },
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
            capacity: { [weak preferences] in preferences?.capacity ?? CapacityPreferences() },
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
            isLive: { [weak store] in store?.statuses[$0] != nil })
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
/// store-ready hops. It ticks every 5 s: scan the mod's files, fold headless seats, turn
/// rate-limit API errors into refusals, poll codex at most every 120 s per account with a live
/// codex tab, flag a silent mod, and tell manual tabs once when their account crosses hard.
@MainActor
final class UsageService: ObservableObject {
    static let shared = UsageService()

    static let tickInterval: Duration = .seconds(5)
    static let codexPollInterval: TimeInterval = 120
    /// A stuck app-server must not hold the tick: `CodexRPC.request` has no timeout of its own.
    static let defaultCodexReadTimeout: TimeInterval = 20
    static let modSilenceGrace: TimeInterval = 15 * 60
    static let fileRetention: TimeInterval = 7 * 24 * 3600
    static let modSilenceMessage = "No reading from Flight Deck's usage mod in this account's tabs for 15 minutes. Its Claude plugin may not be loaded."

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

    private var modSource: ClaudeModUsageSource
    private let headless = HeadlessClaudeUsageSource()
    private var codexSources: [UUID: CodexRateLimitSource] = [:]
    private var lastCodexPoll: [UUID: Date] = [:]
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
        modSource = ClaudeModUsageSource(directory: environment.usageDirectory)
        reconfigure()
    }

    /// The real `HandoffPlanner`, for L3-S to give the `HandoffDriver` at integration. The
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
        modSource.prune(olderThan: Self.fileRetention, now: now())
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
        modSource = ClaudeModUsageSource(directory: new.usageDirectory)
    }

    /// L3-S answers "is this tab a swarm agent?" at integration. Until then every tab is
    /// manual: it gets the one-time notice and is never handed off.
    func setSwarmPredicate(_ isSwarm: @escaping @MainActor (UUID) -> Bool) {
        swarmPredicate = isSwarm
    }

    func reconfigure() {
        let accounts = environment.accounts()
        ledger.configure(pools: environment.capacity().effectivePools(accounts: accounts),
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
        for s in sessions where firstSeen[s.id] == nil { firstSeen[s.id] = t }
        ingestModFiles(sessions)
        ingestHeadlessSeats()
        ingestAPIErrors(sessions, at: t)
        await pollCodex(sessions, at: t)
        flagSilentMod(sessions, at: t)
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

    private func ingestModFiles(_ sessions: [Session]) {
        for (stem, file) in modSource.scan() {
            guard let tab = sessions.first(where: { $0.agent == .claude && ($0.id == stem || $0.pinnedConversationID == stem) }),
                  let ref = accountRef(for: tab) else { continue }
            reported.insert(tab.id)
            ingest(UsageReading(account: ref, windows: file.windows, readAt: file.readAt, source: "claude mod", hardRejection: false))
        }
    }

    /// Headless seats run with Flight Deck's own environment, so they bill the built-in claude
    /// account (see `IntakeRunnerController`'s environment recipe).
    private func ingestHeadlessSeats() {
        guard let id = environment.resolvedAccountID(.claude, nil), let ref = ref(forAccount: id) else { return }
        for reading in headless.readings(from: environment.seatActivities(), account: ref) { ingest(reading) }
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

    private func flagSilentMod(_ sessions: [Session], at t: Date) {
        var tabsByAccount: [UUID: [Session]] = [:]
        for s in sessions where s.agent == .claude {
            if let id = environment.resolvedAccountID(.claude, s.accountID) { tabsByAccount[id, default: []].append(s) }
        }
        for (id, tabs) in tabsByAccount where ledger.latestReading(account: id) == nil && !tabs.contains(where: { reported.contains($0.id) }) {
            let oldest = tabs.compactMap { firstSeen[$0.id] }.min() ?? t
            if t.timeIntervalSince(oldest) >= Self.modSilenceGrace { ledger.setSourceError(Self.modSilenceMessage, account: id) }
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
        // The first tick only records what is already over hard. The mod's files persist across a
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
