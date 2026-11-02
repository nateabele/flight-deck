import Combine
import CryptoKit
import FleetKit
import Foundation
import HostKit
import OSLog

/// What `up` and `down` report as they go: one line per step for the CLI and the setup sheet.
enum InfraEvent: Equatable, Sendable {
    case progress(String)
    /// The spec §8.4 line.
    case cost(String)
    case ready(InfraMachine)
    case failed(String)
}

/// Every seam `InfraService` reaches the outside world through, so a test fakes each one and
/// no test ever creates a cloud resource.
struct InfraEnvironment {
    /// The OpenTofu runner for a resolved `tofu` and the complete environment it must run with.
    var tofu: (ResolvedTool, [String: String]) -> TofuRunning
    var resolver: ToolResolver
    /// By cloud: "aws", "gcp".
    var accounts: [String: CloudAccount]
    var prices: PriceCatalog
    var tailnet: TailnetIntegration
    /// This Mac's public IPv4, for public mode's one firewall rule.
    var publicIP: () async throws -> String
    var presetsRoot: URL
    /// This build's `LinuxHostInstaller` release base URL and installer digest.
    var installer: (base: String, sha256: String)
    var controllerName: String
    /// A stable id for this controller (the install's id). Only its hash leaves the Mac, as the
    /// `flightdeck-owner` label the orphan check finds this controller's resources by.
    var controllerID: String
    var now: () -> Date
    var budget: () -> BudgetSettings
    /// The environment every tool starts from; the login-shell-repaired app environment.
    /// Async and `@Sendable`, so it runs off the main actor: the real one waits on a login
    /// shell the first time, and `resumeAfterLaunch` reaches it from launch.
    var baseEnvironment: @Sendable () async -> [String: String] = { InfraToolEnvironment.defaultBase() }
    /// How long a machine has to say hello once it has an address (spec §5.1: 10 minutes).
    var enrollTimeout: TimeInterval = 600
    /// How often the enroll wait asks the cloud whether the instance is still running: a boot
    /// that cannot enroll powers itself off, and `up` should fail then, not at the timeout.
    var instancePoll: TimeInterval = 30
    /// How often, and for how long, `up` asks the Tailscale API whether the machine has joined.
    var tailnetJoin: (interval: TimeInterval, timeout: TimeInterval) = (2, 300)
    /// At launch, how long an enrolling machine's link gets to come up before a machine already
    /// past its enroll window is destroyed: `HostService.start()` reads keys asynchronously, so
    /// "offline" at the first look only means "not dialled yet". Longer than one full HostLink
    /// backoff cycle (1+2+4+8+16+30+30 s), so a host that is up is dialled at least once.
    var launchGrace: TimeInterval = 90
}

/// The cloud machines' state machine (spec §7.1) and every `infra.*` operation: preflight,
/// create, enroll as a host, destroy, extend, and picking up where a relaunch left off.
///
/// Every state is written to `infra.json` before the step it names begins, so a crash at any
/// point leaves a record a relaunch can resume or destroy — never a machine nobody knows about.
@MainActor
final class InfraService: InfraSessionHooks {
    let registry: InfraRegistry
    let ledger: CostLedger
    let budgets: SessionBudgets
    /// What Flight Deck created, and so all it ever deletes.
    let provenance: ResourceProvenance
    let hosts: HostService
    private let env: InfraEnvironment
    /// Called after an `infra.*` request (or a `run --on` auto-up) finishes, however it ended:
    /// `SessionCloudMonitor` refreshes then rather than waiting for its next tick, so the
    /// sidebar and a phone see a machine appear or go at once.
    var onOperationFinished: (() -> Void)?
    /// One provisioning task per tool: a second caller awaits the first's download instead of
    /// racing it into the same managed directory (Task 6 has no lock of its own).
    private var resolving: [InfraTool: Task<ResolvedTool, Error>] = [:]
    /// Names an `up` or `down` is working on, lowercased. Claimed with no suspension between
    /// the check and the insert, so two operations on one machine can never interleave.
    private var busy: Set<String> = []
    /// Each `up` in flight and its worst case, counted by the next launch's guardrails until
    /// it is done: without it two `up`s could both pass max-concurrent and the monthly cap.
    private var launching: [String: Double] = [:]
    /// Each `up` in flight that belongs to a session, and what it will bill until when: the
    /// next launch of that session counts it, as `launching` counts its worst case.
    private var launchingBurns: [String: (session: UUID, burn: SessionBudgetModel.Burn)] = [:]

    /// How many times each session has closed. An `up` reads its session's count when it starts
    /// and rolls its machine back if the count moved before it finished. A count, not a set of
    /// closed ids: reopening a session reuses its id, and a reopened session may provision again.
    private var sessionCloses: [UUID: Int] = [:]

    private static let logger = Logger(subsystem: "dev.flightdeck.FlightDeck", category: "infra")
    /// Tailscale auth keys outlive the boot that redeems them by this much at most.
    static let authKeyExpiry = HostKit.Duration(seconds: 900)

    init(registry: InfraRegistry, ledger: CostLedger, budgets: SessionBudgets, provenance: ResourceProvenance,
         hosts: HostService, env: InfraEnvironment) {
        self.provenance = provenance
        self.registry = registry
        self.ledger = ledger
        self.budgets = budgets
        self.hosts = hosts
        self.env = env
    }

    // MARK: - Tools

    /// `progress` (0...1) reaches only the caller that starts a download; one that joins an
    /// in-flight provision just waits for it.
    func tool(_ tool: InfraTool, progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> ResolvedTool {
        if let inFlight = resolving[tool] { return try await inFlight.value }
        let resolver = env.resolver
        let task = Task { try await resolver.resolve(tool, provision: true, progress: progress) }
        resolving[tool] = task
        defer { resolving[tool] = nil }
        return try await task.value
    }

    private func tofu(cloud: String) async throws -> TofuRunning {
        let tofu = try await tool(.tofu)
        let base = await env.baseEnvironment()
        let environment = InfraToolEnvironment.make(base: base, tool: tofu.environment,
                                                    provider: env.accounts[cloud]?.providerEnvironment() ?? [:])
        return env.tofu(tofu, environment)
    }

    // MARK: - up

    /// `owner` is who asked: a machine a session creates is that session's, counted against
    /// its budget, given a deadline no later than when that budget runs out, and destroyed when
    /// the session closes. There is no default: nothing is provisioned without an owner.
    func up(name: String, config: InfraConfig, repoRoot: URL, owner: InfraOwner,
            events: @escaping (InfraEvent) -> Void) async throws -> InfraMachine {
        let session = owner.session
        let closesAtStart = session.map { sessionCloses[$0, default: 0] }
        try claim(name)
        defer { release(name) }
        let repo = repoRoot.standardizedFileURL
        if let running = try takeOver(name, repo: repo, owner: owner) {
            events(.cost(costLine(for: running, now: env.now())))
            return running
        }

        let cloud = Self.cloud(of: config, accounts: env.accounts)
        let plan = InfraLaunchPlan(name: name, config: config, cloud: cloud, moduleSource: moduleSource(config, repo),
                              catalogHourly: await price(config, cloud: cloud))
        // Reserve this launch and read everyone else's in one synchronous step: of two
        // concurrent `up`s, the later one always sees the earlier.
        let key = name.lowercased()
        let hourly = plan.catalogHourly ?? config.maxHourly
        let ttlDeadline = env.now().addingTimeInterval(TimeInterval(config.ttl.seconds))
        // Before anything is reserved: a refusal here leaves nothing to undo.
        let budgetDeadline = try sessionLaunchDeadline(name: name, session: session, hourly: hourly, ttlDeadline: ttlDeadline)
        // Non-nil exactly when the session has a budget, which then also prices the machine.
        if let session, let hourly, let budgetDeadline {
            launchingBurns[key] = (session, .init(hourlyUSD: hourly, until: budgetDeadline))
        }
        let others = launching.filter { $0.key != key }
        launching[key] = (plan.catalogHourly ?? config.maxHourly).map { CostModel.worstCase(hourly: $0, ttl: config.ttl) } ?? 0
        let counted = Set(registry.machines.filter { $0.state != .gone }.map { $0.name.lowercased() }).union(others.keys)
        let running = counted.subtracting([key]).count
        let monthToDate = ledger.monthToDate(now: env.now()) + others.values.reduce(0, +)
        let account = cloud.flatMap { env.accounts[$0] }
        let mode = await env.tailnet.mode()
        let checks = await InfraPreflight.run(.init(
            plan: plan, resolveTofu: { try await self.tool(.tofu) }, account: account, tailnetMode: mode,
            budget: env.budget(), running: running, monthToDate: monthToDate))
        guard let cloud, checks.allSatisfy(\.ok) else { throw InfraError.preflight(checks) }
        if case .notConfigured = mode {
            events(.progress("Tailscale is running but not set up for Flight Deck, so \(name) uses public mode; Settings → Cloud → Set up… turns on tailnet mode."))
        }

        let createdAt = env.now()
        let deadline = min(createdAt.addingTimeInterval(TimeInterval(config.ttl.seconds)), budgetDeadline ?? .distantFuture)
        if let budgetDeadline, budgetDeadline < ttlDeadline {
            events(.progress("this session's budget runs out in \(Self.span(budgetDeadline.timeIntervalSince(createdAt))), so \(name) is destroyed then rather than at its \(config.ttl.formatted) TTL"))
        }
        let client: TailscaleOAuthClient? = if case .available(let c) = mode { c } else { nil }
        var machine = InfraMachine(
            name: name, repoRoot: repo.path, cloud: cloud, instanceType: config.instanceType ?? "",
            region: config.region ?? "", slot: nil, state: .planned, failure: nil,
            network: client == nil ? .public : .tailnet, createdAt: createdAt, deadline: deadline, idle: config.idle,
            allowCIDR: nil, instanceID: nil, address: nil, hourlyUSD: plan.catalogHourly ?? config.maxHourly,
            machineDeadline: deadline, session: session)
        try registry.upsert(machine)

        var applyBegan = false
        do {
            try await provision(&machine, plan: plan, client: client, account: account, applyBegan: &applyBegan, events: events)
        } catch {
            let message = Self.failureText(error)
            if applyBegan {
                machine.state = .failed
                machine.failure = message
                do { try registry.upsert(machine) } catch {
                    Self.logger.error("\(name, privacy: .public): could not record the failure: \(String(describing: error), privacy: .public)")
                }
            } else {
                // Nothing was created and no cost segment was opened, so there is nothing for
                // `down` to find: the record, its host and its work directory go, and the
                // session budget never counts it.
                do { try discard(machine) } catch {
                    Self.logger.error("\(name, privacy: .public): could not remove the unapplied record: \(String(describing: error), privacy: .public)")
                }
            }
            events(.failed(message))
            // Once an apply began, something may be running and billing, and nothing will use
            // it: destroyed now, under this `up`'s claim.
            if applyBegan { await rollBack(name, events: events) }
            throw error
        }
        // The session closed while this was coming up: nothing will use it, and its close found
        // the name claimed, so it is destroyed here, under this `up`'s claim.
        if let session, sessionCloses[session, default: 0] != closesAtStart {
            await rollBack(name, events: events)
            throw InfraError.refused("the session that asked for \(name) closed while it was being created, so it was destroyed")
        }
        events(.cost(costLine(for: machine, now: env.now())))
        events(.ready(machine))
        return machine
    }

    /// Steps 2–8 of spec §5.1, from `planned` to `ready`. Any throw leaves `machine` at the
    /// last state it reached, for `up` to mark failed; every step after `apply` began can have
    /// created something, so a failed machine is always kept for `down`.
    private func provision(_ machine: inout InfraMachine, plan: InfraLaunchPlan, client: TailscaleOAuthClient?,
                           account: CloudAccount?, applyBegan: inout Bool,
                           events: @escaping (InfraEvent) -> Void) async throws {
        let name = machine.name, config = plan.config
        let key = FleetDeviceKey.mint()
        try hosts.enroll(key: key, name: name, endpoints: [])
        machine.slot = key.slot
        machine.state = .provisioning
        try registry.upsert(machine)

        let hostname = Self.tailnetHostname(name)
        var authKey: String?
        if let client {
            authKey = try await env.tailnet.mintAuthKey(client: client, tag: TailnetIntegration.cloudTag, expiry: Self.authKeyExpiry)
        } else {
            machine.allowCIDR = "\(try await env.publicIP())/32"
            try registry.upsert(machine)
        }

        let payload = EnrollmentPayload(version: 1, slot: key.slot, secretHex: key.secret.map { String(format: "%02x", $0) }.joined(),
                                        controllerName: env.controllerName, idleSeconds: config.idle.seconds,
                                        issuedAt: machine.createdAt)
        let userData = try CloudInitRenderer.render(payload, CloudInitOptions(
            installerBaseURL: env.installer.base, installerSHA256: env.installer.sha256, deadline: machine.deadline,
            cloud: machine.cloud, tailscaleAuthKey: authKey, tailscaleHostname: authKey == nil ? nil : hostname))
        let workdir = try InfraWorkdir.prepare(
            root: registry.workdir(for: name).deletingLastPathComponent(), name: name, moduleSource: plan.moduleSource,
            vars: moduleVars(name: name, config: config, ttlSeconds: Self.ttlSeconds(machine), userData: userData,
                             allowCIDR: machine.allowCIDR, account: account))

        let tofu = try await tofu(cloud: machine.cloud)
        events(.progress("tofu init"))
        try await tofu.initialize(workdir: workdir)
        // The plan is checked before anything exists, and the apply runs only that plan.
        let changes = try await tofu.plan(workdir: workdir, destroy: false)
        try ResourceProvenance.checkUp(changes, name: name)
        // Billing starts with the apply, not with `ready`: a failed apply can still leave a
        // running instance, and its hours are real until `down` closes the segment.
        let applyStart = env.now()
        applyBegan = true
        if let rate = machine.hourlyUSD { try ledger.open(name: name, hourlyUSD: rate, at: applyStart, session: machine.session) }
        do {
            try await Self.forwardingProgress(events) { try await tofu.applyPlan(workdir: workdir, destroy: false, progress: $0) }
        } catch {
            // A failed apply may still have created some of it, which the rollback deletes.
            await recordCreated(changes, tofu: tofu, workdir: workdir, machine: machine)
            throw error
        }
        await recordCreated(changes, tofu: tofu, workdir: workdir, machine: machine)

        let outputs = try await tofu.outputs(workdir: workdir)
        machine.instanceID = outputs.instanceID
        if machine.hourlyUSD == nil, let rate = outputs.hourlyUSD {
            machine.hourlyUSD = rate
            try ledger.open(name: name, hourlyUSD: rate, at: applyStart, session: machine.session)
        }
        try registry.upsert(machine)

        // Tailnet mode's address is the node's tailnet IP, never the module's output (whose
        // public IP exists only for egress and has no inbound rule).
        let address: String?
        if let client {
            events(.progress("waiting for \(hostname) to join the tailnet"))
            address = try await joinedAddress(client: client, hostname: hostname, events: events)
        } else {
            address = outputs.address
        }
        guard let address else { throw InfraError.enrollTimeout(console: await console(machine, account)) }
        machine.address = address
        hosts.setEndpoints(slot: key.slot, [Self.endpoint(address)])
        machine.state = .enrolling
        machine.enrollingSince = env.now()
        try registry.upsert(machine)

        events(.progress("waiting for \(name) to enroll"))
        switch await waitEnrolled(slot: key.slot, machine: machine, account: account) {
        case .online: break
        case .ended: throw InfraError.enrollFailed(console: await console(machine, account))
        case .timedOut: throw InfraError.enrollTimeout(console: await console(machine, account))
        }
        machine.state = .ready
        try registry.upsert(machine)
    }

    /// Polls the Tailscale API until the machine's node has an address, signing it under
    /// Tailnet Lock on the way when this Mac can. Nil when it never joined in time.
    private func joinedAddress(client: TailscaleOAuthClient, hostname: String,
                               events: @escaping (InfraEvent) -> Void) async throws -> String? {
        let giveUp = Date().addingTimeInterval(env.tailnetJoin.timeout)
        var lockHandled = false
        while true {
            if let node = try await env.tailnet.cloudNode(client: client, hostname: hostname) {
                if !lockHandled, let nodeKey = node.nodeKey {
                    lockHandled = true
                    if await env.tailnet.local().lockEnabled {
                        let signed = try await env.tailnet.signIfSigner(nodeKey: nodeKey)
                        events(.progress(signed
                            ? "signed \(hostname) under Tailnet Lock"
                            : "Tailnet Lock is on and this Mac is not a signer: run `tailscale lock sign \(nodeKey)` on a signing device"))
                    }
                }
                if let address = node.address { return address }
            }
            guard Date() < giveUp else { return nil }
            try await Task.sleep(nanoseconds: UInt64(env.tailnetJoin.interval * 1_000_000_000))
        }
    }

    private enum EnrollWait { case online, ended, timedOut }

    /// `slot` coming online within the enroll timeout, asking the cloud every `instancePoll`
    /// whether the instance still runs: a boot that cannot install or enroll hostd powers
    /// itself off on AWS, and waiting out the timeout for it would only bill.
    private func waitEnrolled(slot: UUID, machine: InfraMachine, account: CloudAccount?) async -> EnrollWait {
        guard let account, let id = machine.instanceID else {
            return await waitOnline(slot: slot, timeout: env.enrollTimeout) ? .online : .timedOut
        }
        let giveUp = Date().addingTimeInterval(env.enrollTimeout)
        while true {
            let left = giveUp.timeIntervalSinceNow
            guard left > 0 else { return .timedOut }
            if await waitOnline(slot: slot, timeout: min(env.instancePoll, left)) { return .online }
            if await account.instanceEnded(instanceID: id, region: machine.region) { return .ended }
        }
    }

    /// Destroys a machine whose `up` failed after its apply began. Its progress goes to
    /// `events`, but a destroy failure only as progress: the `up`'s own failure stays the one
    /// reported. A failed destroy leaves the machine `failed` with its attempt counted, for the
    /// Reaper to retry.
    /// Records what an apply of `changes` created. A failure is logged, never thrown: the
    /// resources exist either way, and without a record the destroy that follows refuses to
    /// touch them, which leaves them for the user rather than deleting the unknown.
    private func recordCreated(_ changes: [TofuChange], tofu: TofuRunning, workdir: URL, machine: InfraMachine) async {
        do {
            let state = try await tofu.resources(workdir: workdir)
            try provenance.record(ResourceProvenance.created(by: changes, state: state, cloud: machine.cloud,
                                                              machine: machine.name, at: env.now()))
        } catch {
            Self.logger.error("\(machine.name, privacy: .public): created resources not recorded: \(String(describing: error), privacy: .public)")
        }
    }

    private func rollBack(_ name: String, events: @escaping (InfraEvent) -> Void) async {
        events(.progress("destroying \(name), which failed before it was ready"))
        do {
            try await destroyClaimed(name: name) { event in
                if case .failed(let why) = event { events(.progress(why)) } else { events(event) }
            }
        } catch {
            events(.progress("\(name) could not be destroyed yet; Flight Deck retries, and `flightdeck infra down \(name)` tries now"))
        }
    }

    /// True once `slot`'s link reports online, false after `timeout`.
    private func waitOnline(slot: UUID, timeout: TimeInterval) async -> Bool {
        if case .online = hosts.statuses[slot] { return true }
        var subscription: AnyCancellable?
        var timer: Task<Void, Never>?
        defer { subscription?.cancel(); timer?.cancel() }
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            var settled = false
            let settle = { (online: Bool) in
                guard !settled else { return }
                settled = true
                continuation.resume(returning: online)
            }
            subscription = hosts.$statuses.sink { statuses in
                if case .online = statuses[slot] { settle(true) }
            }
            timer = Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1_000_000_000))
                settle(false)
            }
        }
    }

    private func console(_ machine: InfraMachine, _ account: CloudAccount?) async -> String? {
        guard let account, let id = machine.instanceID else { return nil }
        return await account.consoleOutput(instanceID: id, region: machine.region)
    }

    /// The machine `up` should hand back as it is, or nil for a free name. Every other use of
    /// the name refuses before anything is checked or created (Review Focus 3).
    private func takeOver(_ name: String, repo: URL, owner: InfraOwner) throws -> InfraMachine? {
        if let m = registry.machines.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            guard m.repoRoot == repo.path else {
                throw InfraError.nameInUse("\(name) is a cloud machine of another repo, \(m.repoRoot); pick another name")
            }
            switch m.state {
            case .ready, .idle:
                // A machine is destroyed with its session, so it is never handed to another one.
                if let holder = m.session, holder != owner.session {
                    throw InfraError.nameInUse("\(name) belongs to another Flight Deck session; pick another name")
                }
                // A machine from before ownership was recorded belongs to the first session to ask.
                if m.session == nil, let session = owner.session {
                    var claimed = m
                    claimed.session = session
                    try registry.upsert(claimed)
                    return claimed
                }
                return m
            case .failed, .orphaned, .gone:
                throw InfraError.nameInUse("\(name) is \(m.state.rawValue); run `flightdeck infra down \(name)` first")
            case .planned, .provisioning, .enrolling, .destroying:
                throw InfraError.nameInUse("\(name) is already \(m.state.rawValue)")
            }
        }
        if case .success = hosts.registry.resolve(name: name) {
            throw InfraError.nameInUse("\(name) is already a paired host; pick another name or forget that host in Settings → Hosts")
        }
        return nil
    }

    // MARK: - session close

    /// The session's tab closed: every machine it owns is destroyed. One that is mid-`up` holds
    /// its name's claim, so `up` destroys it itself when it finishes (it sees the session here);
    /// one mid-`down` is already going. Failures are logged, and the Reaper retries them.
    func sessionClosed(_ session: UUID) {
        sessionCloses[session, default: 0] += 1
        let names = registry.machines.filter { $0.session == session && $0.state != .gone }.map(\.name)
        for name in names where !busy.contains(name.lowercased()) {
            Task {
                await downLogged(name)
                onOperationFinished?()
            }
        }
    }

    // MARK: - down

    func down(name: String, events: @escaping (InfraEvent) -> Void) async throws {
        try claim(name)
        defer { release(name) }
        try await destroyClaimed(name: name, events: events)
    }

    /// `down`'s work, for a caller that already holds the name's claim.
    private func destroyClaimed(name: String, events: @escaping (InfraEvent) -> Void) async throws {
        guard var machine = registry.machine(named: name) else { throw InfraError.notFound(name) }
        machine.state = .destroying
        try registry.upsert(machine)

        let workdir = registry.workdir(for: name)
        // No module directory means `up` failed before preparing it, so nothing was applied.
        if FileManager.default.fileExists(atPath: workdir.appendingPathComponent("module").path) {
            do {
                let tofu = try await tofu(cloud: machine.cloud)
                events(.progress("destroying \(name)"))
                // Every resource the plan would delete must be one Flight Deck created, or
                // nothing is deleted at all; then exactly that plan runs.
                let changes = try await tofu.plan(workdir: workdir, destroy: true)
                try provenance.checkDestroy(changes, cloud: machine.cloud, name: name)
                try await Self.forwardingProgress(events) { try await tofu.applyPlan(workdir: workdir, destroy: true, progress: $0) }
            } catch {
                // Never removed while resources may still exist: the record is how anyone finds them.
                let message = "destroy: " + Self.failureText(error)
                recordDestroyFailure(&machine, message)
                events(.failed(message))
                throw error
            }
        }
        if machine.network == .tailnet, case .available(let client) = await env.tailnet.mode() {
            // Best effort: an ephemeral node leaves the tailnet on its own once it is offline.
            do { try await env.tailnet.deleteNode(client: client, hostname: Self.tailnetHostname(name)) } catch {
                Self.logger.error("\(name, privacy: .public): tailnet node not deleted: \(String(describing: error), privacy: .public)")
            }
        }
        do { try ledger.close(name: name, at: env.now()) } catch {
            // Kept, never forgotten: a record removed with its segment still open would bill
            // this machine into every month-to-date from now on, with nothing left to close it.
            let message = "destroyed, but the cost ledger could not be written (\(error.localizedDescription)); run `flightdeck infra down \(name)` again"
            recordDestroyFailure(&machine, message)
            events(.failed(message))
            throw error
        }
        try discard(machine)
        events(.progress("\(name) destroyed"))
    }

    /// A failed `down` is counted and timed, so the Reaper can retry it with backoff; a machine
    /// that failed during `up` has no count and is left for the user.
    private func recordDestroyFailure(_ machine: inout InfraMachine, _ message: String) {
        machine.state = .failed
        machine.failure = message
        machine.destroyAttempts = (machine.destroyAttempts ?? 0) + 1
        machine.lastDestroyAt = env.now()
        try? registry.upsert(machine)
    }

    /// Forgets a machine whose resources are destroyed and whose cost segment is closed: its
    /// host and key, its work directory, and finally its record.
    private func discard(_ machine: InfraMachine) throws {
        if let slot = machine.slot {
            hosts.forget(slot: slot)
        } else if case .success(let host) = hosts.registry.resolve(name: machine.name), host.serviceName == "fd-\(machine.name)" {
            // Enrolled, then interrupted before the slot reached `infra.json`.
            hosts.forget(slot: host.slot)
        }
        try? FileManager.default.removeItem(at: registry.workdir(for: machine.name))
        try registry.remove(name: machine.name)
    }

    // MARK: - extend

    /// Plan deviation 6: the machine's own timer (AWS's poweroff timer, GCP's
    /// `max_run_duration`) was fixed at creation, so this moves only the controller's deadline,
    /// and never past that timer — after a Reaper warning or an earlier reduction. The budget
    /// is re-checked for the new span: its worst case, from now, on top of what is spent.
    func extend(name: String, by: HostKit.Duration) async throws -> InfraMachine {
        guard var machine = registry.machine(named: name) else { throw InfraError.notFound(name) }
        guard machine.state == .ready || machine.state == .idle else {
            throw InfraError.refused("\(name) is \(machine.state.rawValue); only a running machine can be extended")
        }
        let now = env.now()
        let limit = machine.machineDeadline ?? machine.deadline
        let proposed = machine.deadline.addingTimeInterval(TimeInterval(by.seconds))
        guard proposed <= limit.addingTimeInterval(1) else {
            throw InfraError.refused("\(name) can run \(Self.span(limit.timeIntervalSince(now))) more at most: the machine's own timer was set at creation; run `flightdeck infra down \(name)` and `up` again to run longer")
        }
        if let session = machine.session, let b = budgets.budget(for: session) {
            let status = sessionStatus(session, now: now, replacing: (name.lowercased(), proposed))
            if let end = status.exhaustsAt, end < proposed {
                let left = InfraPreflight.usd(max(0, b.capUSD - status.spent))
                throw InfraError.refused("This session's budget has \(left) of \(InfraPreflight.usd(b.capUSD)) left, which runs out in \(Self.span(end.timeIntervalSince(now))) at the session's current rates; `/budget <usd>` raises it.")
            }
        }
        let budget = env.budget()
        if let rate = machine.hourlyUSD {
            let remaining = HostKit.Duration(seconds: max(0, Int(proposed.timeIntervalSince(now).rounded(.up))))
            let worst = CostModel.worstCase(hourly: rate, ttl: remaining)
            let spent = ledger.spent(name: name, now: now), month = ledger.monthToDate(now: now)
            let usd = InfraPreflight.usd
            if let cap = budget.perMachineCapUSD, spent + worst > cap + 1e-9 {
                throw InfraError.refused("\(usd(spent)) spent plus up to \(usd(worst)) more is over the \(usd(cap)) per-machine cap; raise Per-machine cap in Settings → Cloud → Budget.")
            }
            if let cap = budget.monthlyCapUSD, month + worst > cap + 1e-9 {
                throw InfraError.refused("\(usd(month)) spent this month plus up to \(usd(worst)) more is over the \(usd(cap)) monthly cap; raise Monthly cap in Settings → Cloud → Budget.")
            }
        } else if budget.hasDollarCap {
            throw InfraError.refused("Can't price \(name), so a dollar cap can't be enforced; clear the caps in Settings → Cloud → Budget to extend it.")
        }
        machine.deadline = proposed
        try registry.upsert(machine)
        return machine
    }

    // MARK: - Session budgets

    /// What one session's budget stands at: spent in its window, what its machines bill now,
    /// and when the budget runs out if they keep running to their deadlines. Every figure comes
    /// from the ledger and the registry alone, so the same records always give the same answer.
    struct SessionStatus {
        let budget: SessionBudget?
        let spent: Double
        let hourly: Double
        /// Nil with no budget, or when every machine's deadline comes first; `now` once used up.
        let exhaustsAt: Date?
        /// Its machines that still exist, by name.
        let machines: [String]
        var exhausted: Bool { exhaustsAt.map { $0 <= now } ?? false }
        let now: Date
    }

    /// `replacing` gives one machine (by lowercased name) another deadline, for `extend` to ask
    /// what the session would look like with it.
    func sessionStatus(_ session: UUID, now: Date, replacing: (String, Date)? = nil) -> SessionStatus {
        let budget = budgets.budget(for: session)
        let spent = ledger.spent(session: session, since: budget?.since ?? .distantPast, now: now)
        var burns = sessionBurns(session, now: now)
        if let (key, until) = replacing, let burn = burns[key] { burns[key] = .init(hourlyUSD: burn.hourlyUSD, until: until) }
        let live = burns.values.filter { $0.until > now }
        let exhausts = budget.flatMap { SessionBudgetModel.exhaustion(remaining: $0.capUSD - spent, burns: Array(live), now: now) }
        let machines = registry.machines.filter { $0.session == session }.map(\.name).sorted()
        return SessionStatus(budget: budget, spent: spent, hourly: live.reduce(0) { $0 + $1.hourlyUSD },
                             exhaustsAt: exhausts, machines: machines, now: now)
    }

    /// What each of the session's machines will bill from now, by lowercased name: every one
    /// that exists and can be priced (a failed one may still be running), and every `up` of the
    /// session in flight, until its deadline.
    private func sessionBurns(_ session: UUID, now: Date, excluding key: String? = nil) -> [String: SessionBudgetModel.Burn] {
        var burns: [String: SessionBudgetModel.Burn] = [:]
        for m in registry.machines where m.session == session && m.state != .gone {
            guard let rate = m.hourlyUSD else { continue }
            burns[m.name.lowercased()] = .init(hourlyUSD: rate, until: m.deadline)
        }
        for (k, v) in launchingBurns where v.session == session { burns[k] = v.burn }
        if let key { burns[key] = nil }
        return burns
    }

    /// The deadline a session's budget gives a new machine, nil when it sets none (no session,
    /// or no budget); throws the refusal when the budget is used up or would end it at once.
    private func sessionLaunchDeadline(name: String, session: UUID?, hourly: Double?, ttlDeadline: Date) throws -> Date? {
        guard let session, let b = budgets.budget(for: session) else { return nil }
        let now = env.now()
        let spent = ledger.spent(session: session, since: b.since, now: now)
        let burns = Array(sessionBurns(session, now: now, excluding: name.lowercased()).values)
        switch SessionBudgetModel.checkLaunch(name: name, hourly: hourly, ttlDeadline: ttlDeadline, remaining: b.capUSD - spent,
                                              capUSD: b.capUSD, burns: burns, now: now) {
        case .refused(let why):
            throw InfraError.preflight([PreflightCheck(name: "session budget", ok: false, detail: why, fix: nil)])
        case .allowed(let deadline):
            return deadline
        }
    }

    /// `infra.budget`: changes the session's budget as asked, then says where it stands.
    func budget(_ action: InfraRequest.BudgetAction, session: UUID) throws -> WireSessionBudget {
        let now = env.now()
        switch action {
        case .show: break
        case .set(let usd):
            try Self.validCap(usd)
            try budgets.set(session, capUSD: usd, now: now)
        case .renew(let usd):
            if let usd { try Self.validCap(usd) }
            guard try budgets.renew(session, capUSD: usd, now: now) != nil else {
                throw InfraError.refused("this session has no budget to renew; give an amount, as `/budget renew 20`")
            }
        case .clear:
            try budgets.clear(session)
        }
        return wire(sessionStatus(session, now: now), session: session)
    }

    private static func validCap(_ usd: Double) throws {
        guard usd.isFinite, usd > 0 else {
            throw InfraError.refused("a budget must be a positive number of dollars, as `/budget 20`")
        }
    }

    func wire(_ s: SessionStatus, session: UUID) -> WireSessionBudget {
        let usd = InfraPreflight.usd
        let remaining = s.budget.map { max(0, $0.capUSD - s.spent) }
        var parts: [String]
        if let b = s.budget {
            parts = ["session budget \(usd(b.capUSD))", "spent ~\(usd(s.spent))", "\(usd(remaining ?? 0)) left"]
        } else {
            parts = ["no cloud budget for this session", "its machines spent ~\(usd(s.spent))"]
        }
        if s.hourly > 0 { parts.append("\(usd(s.hourly))/h now") }
        if s.budget != nil {
            if s.exhausted {
                parts.append(s.machines.isEmpty ? "used up; `/budget renew` starts a fresh one" : "used up: its machines are being destroyed")
            }
            else if let end = s.exhaustsAt { parts.append("runs out in \(Self.span(end.timeIntervalSince(s.now)))") }
            else if s.hourly > 0 { parts.append("lasts past every machine's TTL") }
        }
        if !s.machines.isEmpty { parts.append(s.machines.joined(separator: ", ")) }
        let iso = ISO8601DateFormatter()
        return WireSessionBudget(
            session: session.uuidString, capUsd: s.budget?.capUSD, since: s.budget.map { iso.string(from: $0.since) },
            spentUsd: s.spent, remainingUsd: remaining, hourlyUsd: s.hourly,
            exhaustsIn: s.exhaustsAt.map { max(0, Int($0.timeIntervalSince(s.now))) }, machines: s.machines,
            line: parts.joined(separator: " · "))
    }

    // MARK: - list, doctor

    func list(now: Date) -> [InfraMachine] {
        registry.machines.sorted { $0.createdAt < $1.createdAt }
    }

    /// The same checks `up` makes, with no recipe: the tool (never downloaded from here), every
    /// account, the network mode, each failed machine with what to do about it, and the orphan
    /// scan (spec §7.3).
    func doctor() async -> [PreflightCheck] {
        let resolver = env.resolver
        var checks = [await InfraPreflight.tools { try await resolver.resolve(.tofu, provision: false) }]
        for (cloud, account) in env.accounts.sorted(by: { $0.key < $1.key }) {
            checks.append(await InfraPreflight.account(cloud: cloud, account, name: "account \(cloud)"))
        }
        checks.append(InfraPreflight.network(await env.tailnet.mode()))
        for m in registry.machines where m.state == .failed {
            // A record written before failures were redacted still is, on the way out.
            let failure = SecretRedaction.redact(m.failure ?? "failed")
            checks.append(PreflightCheck(name: "machine \(m.name)", ok: false, detail: failure,
                                         fix: InfraPreflight.fix(forFailure: failure) ?? "flightdeck infra down \(m.name)"))
        }
        return checks + orphanChecks(await orphans())
    }

    /// Spec §7.3's scan as doctor rows: each orphan with the command that deletes it, each
    /// account that could not be read, and an all-clear only when every account was.
    private func orphanChecks(_ scan: OrphanScan) -> [PreflightCheck] {
        var checks = scan.found.map { r in
            // Only a resource Flight Deck recorded creating is one `down --orphan` deletes.
            provenance.created(r)
                ? PreflightCheck(name: "orphan \(r.ref)", ok: false,
                                 detail: "\(r.cloud) \(r.region)\(r.name.map { " (\($0))" } ?? "") is labelled as this Mac's but no machine owns it",
                                 fix: "flightdeck infra down --orphan \(r.ref)")
                : PreflightCheck(name: "orphan \(r.ref)", ok: false,
                                 detail: "\(r.cloud) \(r.region)\(r.name.map { " (\($0))" } ?? "") is labelled as this Mac's, but Flight Deck has no record of creating it",
                                 fix: "delete it in the \(r.cloud) console if it is yours; Flight Deck will not")
        }
        for (cloud, why) in scan.unreadable.sorted(by: { $0.key < $1.key }) {
            checks.append(PreflightCheck(name: "orphan scan \(cloud)", ok: false, detail: "could not scan \(cloud): \(why)",
                                         fix: InfraPreflight.fix(forFailure: why) ?? "check the \(cloud) account in Settings → Cloud"))
        }
        if checks.isEmpty {
            checks.append(PreflightCheck(name: "orphans", ok: true, detail: "none", fix: nil))
        }
        return checks
    }

    // MARK: - Relaunch (Review Focus 1)

    /// Picks up every machine a quit or crash left mid-flight: an enrolled one that came online
    /// is ready; one that never enrolled in time, or whose deadline passed before it was ever
    /// up, is destroyed; a half-destroyed one is destroyed again; one whose instance is already
    /// gone (its own TTL fired) is forgotten. Ready, idle and failed machines are the Reaper's.
    func resumeAfterLaunch() async {
        let now = env.now()
        var enrolling: [InfraMachine] = []
        for m in registry.machines {
            switch m.state {
            case .enrolling:
                if isOnline(m) { markReady(m.name) } else { enrolling.append(m) }
            case .planned, .provisioning:
                // A gone instance is still destroyed first: its security group, firewall rule
                // and the rest of tfstate outlive it.
                let expired = now > m.deadline
                if expired {
                    await downLogged(m.name)
                } else if await refreshShowsGone(m) {
                    await downLogged(m.name)
                }
            case .destroying:
                await downLogged(m.name)
            case .ready, .idle, .failed, .orphaned, .gone:
                break
            }
        }
        await withTaskGroup(of: Void.self) { group in
            for m in enrolling {
                let wait = enrollWait(for: m, now: now)
                group.addTask { @MainActor in
                    if let slot = m.slot, await self.waitOnline(slot: slot, timeout: wait) {
                        self.markReady(m.name)
                    } else {
                        await self.downLogged(m.name)
                    }
                }
            }
        }
    }

    /// What is left of an enrolling machine's window — counted from `enrollingSince`, so a slow
    /// apply does not eat into it — but never less than `launchGrace`.
    func enrollWait(for m: InfraMachine, now: Date) -> TimeInterval {
        let began = m.enrollingSince ?? m.createdAt
        return max(began.addingTimeInterval(env.enrollTimeout).timeIntervalSince(now), env.launchGrace)
    }

    private func isOnline(_ m: InfraMachine) -> Bool {
        guard let slot = m.slot, case .online = hosts.statuses[slot] else { return false }
        return true
    }

    private func markReady(_ name: String) {
        guard var m = registry.machine(named: name) else { return }
        m.state = .ready
        do { try registry.upsert(m) } catch {
            Self.logger.error("\(name, privacy: .public): could not record ready: \(String(describing: error), privacy: .public)")
        }
    }

    /// `refreshShowsGone` holding the name, so no `up`, `down` or address change runs against
    /// the same state meanwhile. Nil when the name is already held: skip, and look next time.
    func refreshClaimed(_ name: String) async -> Bool? {
        guard let m = registry.machine(named: name), (try? claim(name)) != nil else { return nil }
        defer { release(name) }
        return await refreshShowsGone(m)
    }

    /// True when `tofu plan -refresh-only` finds the instance gone (its own timer fired). False
    /// when it is there, when nothing was ever applied, and when the refresh itself fails: a
    /// machine is only ever forgotten on a definite answer.
    func refreshShowsGone(_ m: InfraMachine) async -> Bool {
        let workdir = registry.workdir(for: m.name)
        guard FileManager.default.fileExists(atPath: workdir.appendingPathComponent("module").path) else { return false }
        do { return try await tofu(cloud: m.cloud).refreshShowsGone(workdir: workdir) } catch {
            Self.logger.error("\(m.name, privacy: .public): refresh failed: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    /// `ready ⇄ idle` (spec §7.1), for the UI. Any other state is left alone: the Reaper read
    /// the machine before it suspended, and an `up` or `down` may have moved it since.
    func setIdle(_ name: String, _ idle: Bool) {
        guard var m = registry.machine(named: name), m.state == .ready || m.state == .idle else { return }
        let state: InfraState = idle ? .idle : .ready
        guard m.state != state else { return }
        m.state = state
        do { try registry.upsert(m) } catch {
            Self.logger.error("\(name, privacy: .public): could not record \(state.rawValue, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - Public mode follows the Mac (spec §6.2, Review Focus 5)

    /// Re-points a public-mode machine's one inbound rule at this Mac's current public IP: the
    /// vars file's `fd_allow_cidr`, an `apply`, then the record. Returns the new `/32`, or nil
    /// when nothing changed (tailnet mode, not running, or the address is the same).
    /// Claimed first and the record read under the claim, so a busy machine costs no lookup and
    /// the state checked is the state acted on.
    func followPublicIP(name: String) async throws -> String? {
        try claim(name)
        defer { release(name) }
        guard let m = registry.machine(named: name), m.network == .public, m.state == .ready || m.state == .idle else { return nil }
        let cidr = "\(try await env.publicIP())/32"
        guard cidr != m.allowCIDR else { return nil }
        let workdir = registry.workdir(for: name)
        try InfraWorkdir.setVar(workdir: workdir, "fd_allow_cidr", cidr)
        let tofu = try await tofu(cloud: m.cloud)
        let changes = try await tofu.plan(workdir: workdir, destroy: false)
        try provenance.checkChange(changes, cloud: m.cloud, name: name)
        do { try await tofu.applyPlan(workdir: workdir, destroy: false) { _ in } } catch {
            await recordCreated(changes, tofu: tofu, workdir: workdir, machine: m)
            throw error
        }
        await recordCreated(changes, tofu: tofu, workdir: workdir, machine: m)
        // Re-read: only the address is this call's to change.
        guard var current = registry.machine(named: name) else { return cidr }
        current.allowCIDR = cidr
        try registry.upsert(current)
        return cidr
    }

    // MARK: - Orphans (spec §7.3)

    /// Every resource carrying this controller's owner label that no machine in `infra.json`
    /// accounts for, and every account that could not be read, with why: "none found" is only
    /// "none" when nothing was unreadable.
    func orphans() async -> OrphanScan {
        let owner = ownerLabel
        var scan = OrphanScan(found: [], unreadable: [:])
        for (cloud, account) in env.accounts.sorted(by: { $0.key < $1.key }) {
            do { scan.found += try await account.listOwned(owner: owner) } catch {
                Self.logger.error("orphan scan of \(cloud, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                scan.unreadable[cloud] = Self.failureText(error)
            }
        }
        scan.found = scan.found.filter { !accountsFor($0) }
        return scan
    }

    /// Deletes one orphan by its `kind:id` (`OwnedResource.ref`). Looked up in a fresh scan, so
    /// only something that is an orphan right now can be deleted: never a resource a machine in
    /// the registry owns.
    func downOrphan(id ref: String) async throws {
        guard let orphan = await orphans().found.first(where: { $0.ref == ref }), let account = env.accounts[orphan.cloud] else {
            throw InfraError.notFound(ref)
        }
        // The owner tag found it; only the record says Flight Deck made it.
        guard provenance.created(orphan) else {
            throw InfraError.refused("Flight Deck has no record of creating \(ref), so it will not delete it. If it is yours, delete it in the cloud console.")
        }
        try await account.deleteOwned(orphan)
    }

    /// An instance is a machine's only by the ID it recorded: an older instance of the same
    /// name that leaked must still show up. A GCE machine records `projects/<p>/zones/<z>/
    /// instances/<name>`, which the scan lists by `<name>`. Only a machine with no ID yet (`up`
    /// interrupted before the apply's outputs) claims its instance by name. Security groups
    /// and firewall rules have no ID on the record, so they go by `flightdeck-name`.
    private func accountsFor(_ r: OwnedResource) -> Bool {
        registry.machines.contains { m in
            guard m.cloud == r.cloud else { return false }
            let sameName = r.name.map { $0.caseInsensitiveCompare(m.name) == .orderedSame } ?? false
            guard r.kind == .instance else { return sameName }
            guard let id = m.instanceID else { return sameName }
            return id == r.id || id.split(separator: "/").last.map(String.init) == r.id
        }
    }

    private func downLogged(_ name: String) async {
        do { try await down(name: name) { _ in } } catch {
            Self.logger.error("\(name, privacy: .public): destroy at launch failed: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - Plumbing

    private func claim(_ name: String) throws {
        guard busy.insert(name.lowercased()).inserted else {
            throw InfraError.refused("\(name) is already being created or destroyed")
        }
    }

    private func release(_ name: String) {
        busy.remove(name.lowercased())
        launching[name.lowercased()] = nil
        launchingBurns[name.lowercased()] = nil
    }

    /// Runs one OpenTofu step, handing each resource it starts to `events` in order, and only
    /// returns (or throws) once every one of them has been delivered — so no progress line can
    /// arrive after the `ready` or `failed` that ends the operation.
    private static func forwardingProgress(
        _ events: @escaping (InfraEvent) -> Void,
        _ step: (@escaping @Sendable (TofuProgress) -> Void) async throws -> Void
    ) async throws {
        let (stream, continuation) = AsyncStream.makeStream(of: TofuProgress.self)
        let forward = Task { @MainActor in
            for await p in stream where !p.done { events(.progress("\(p.action) \(p.resource)")) }
        }
        do {
            try await step { continuation.yield($0) }
        } catch {
            continuation.finish()
            await forward.value
            throw error
        }
        continuation.finish()
        await forward.value
    }

    // MARK: - Cost line (spec §8.4)

    /// `gpu · g6.xlarge · $0.80/h est. · up 1h12m · ~$0.96 · TTL 2h48m · month ~$14.20 of $50`
    func costLine(for m: InfraMachine, now: Date) -> String {
        let usd = InfraPreflight.usd
        var parts = [m.name, m.instanceType.isEmpty ? "module" : m.instanceType]
        parts.append(m.hourlyUSD.map { "\(usd($0))/h est." } ?? "price unknown")
        parts.append("up \(Self.span(now.timeIntervalSince(m.createdAt)))")
        if m.hourlyUSD != nil { parts.append("~\(usd(ledger.spent(name: m.name, now: now)))") }
        parts.append("TTL \(Self.span(m.deadline.timeIntervalSince(now)))")
        var month = "month ~\(usd(ledger.monthToDate(now: now)))"
        if let cap = env.budget().monthlyCapUSD {
            month += " of " + (cap == cap.rounded() ? "$\(Int(cap))" : usd(cap))
        }
        parts.append(month)
        if let session = m.session, let b = budgets.budget(for: session) {
            parts.append("session ~\(usd(ledger.spent(session: session, since: b.since, now: now))) of \(usd(b.capUSD))")
        }
        return parts.joined(separator: " · ")
    }

    /// The same figures as `costLine`, as `--json` carries them (spec §8.4), with the line.
    func wire(_ m: InfraMachine, now: Date) -> WireInfraMachine {
        WireInfraMachine(
            name: m.name, cloud: m.cloud, instanceType: m.instanceType, region: m.region, state: m.state.rawValue,
            network: m.network.rawValue, hourlyUsd: m.hourlyUSD, spentUsd: ledger.spent(name: m.name, now: now),
            ttlRemaining: max(0, Int(m.deadline.timeIntervalSince(now))), monthUsd: ledger.monthToDate(now: now),
            monthCapUsd: env.budget().monthlyCapUSD, failure: m.failure, costLine: costLine(for: m, now: now))
    }

    /// The service's clock, so a caller stamps every machine in one answer with the same `now`.
    var now: Date { env.now() }

    /// The monthly dollar cap Settings → Cloud → Budget sets; nil with none.
    var monthlyCapUSD: Double? { env.budget().monthlyCapUSD }

    /// Whole minutes, as `1h12m`; never negative, and `0m` rather than `0s`.
    static func span(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval)) / 60 * 60
        return seconds == 0 ? "0m" : HostKit.Duration(seconds: seconds).formatted
    }

    // MARK: - Pure helpers

    /// A preset names its cloud ("aws-linux"); a user module says so in `vars.cloud`, or is
    /// taken to be for the only cloud with an account.
    static func cloud(of config: InfraConfig, accounts: [String: CloudAccount]) -> String? {
        switch config.source {
        case .preset(let preset): return preset.split(separator: "-").first.map(String.init)
        case .module: return config.vars["cloud"] ?? (accounts.count == 1 ? accounts.keys.first : nil)
        }
    }

    private func moduleSource(_ config: InfraConfig, _ repo: URL) -> URL {
        switch config.source {
        case .preset(let preset): env.presetsRoot.appendingPathComponent(preset, isDirectory: true)
        case .module(let path): repo.appendingPathComponent(path, isDirectory: true)
        }
    }

    private func price(_ config: InfraConfig, cloud: String?) async -> Double? {
        guard case .preset = config.source, let cloud, let region = config.region, let type = config.instanceType else { return nil }
        // 50 GB is the presets' own `disk_gb` default.
        return await env.prices.hourly(PriceQuery(cloud: cloud, region: region, instanceType: type, spot: config.spot,
                                                  diskGB: config.diskGB ?? 50))
    }

    /// Spec §5.3's inputs, the preset's own variables, the account's (`project`), and for a
    /// user module its `vars` — which can never override an `fd_` input.
    private func moduleVars(name: String, config: InfraConfig, ttlSeconds: Int, userData: String, allowCIDR: String?,
                            account: CloudAccount?) -> [String: InfraVar] {
        var vars: [String: InfraVar] = [
            "fd_name": .string(name),
            "fd_user_data": .string(userData),
            "fd_labels": .map(["flightdeck": "1", "flightdeck-owner": ownerLabel, "flightdeck-name": name]),
            // Empty is tailnet mode: no inbound rule at all.
            "fd_allow_cidr": .string(allowCIDR ?? ""),
            // The machine's own timer: the TTL, or less when a session budget ends it sooner.
            "ttl_seconds": .number(Double(ttlSeconds)),
            "spot": .bool(config.spot),
        ]
        if let region = config.region { vars["region"] = .string(region) }
        if let type = config.instanceType { vars["instance_type"] = .string(type) }
        if let arch = config.arch { vars["arch"] = .string(arch) }
        if let disk = config.diskGB { vars["disk_gb"] = .number(Double(disk)) }
        for (k, v) in account?.moduleVars() ?? [:] { vars[k] = .string(v) }
        if case .module = config.source {
            for (k, v) in config.vars where vars[k] == nil { vars[k] = .string(v) }
        }
        return vars
    }

    /// Whole seconds from creation to the deadline, at least 1: the TTL a session budget may
    /// have shortened, as the module's own timer is set to it.
    static func ttlSeconds(_ m: InfraMachine) -> Int {
        max(1, Int(m.deadline.timeIntervalSince(m.createdAt)))
    }

    /// The first 12 lowercase hex characters of SHA-256 of the controller id: the GCP preset
    /// cuts labels to 12, and a hex prefix keeps 48 random bits there, where a hostname-like
    /// owner would collide between controllers sharing a project.
    var ownerLabel: String {
        String(SHA256.hash(data: Data(env.controllerID.utf8)).map { String(format: "%02x", $0) }.joined().prefix(12))
    }

    /// `fd-<name>`, lowercased with anything outside `[a-z0-9-]` made a hyphen, as Tailscale and
    /// `CloudInitRenderer` require.
    static func tailnetHostname(_ name: String) -> String {
        let cleaned = String(name.lowercased().map { ($0.isASCII && ($0.isLetter || $0.isNumber)) || $0 == "-" ? $0 : "-" })
        return String("fd-\(cleaned)".prefix(63))
    }

    /// hostd's port on `address`, bracketing an IPv6 literal so it still splits at its last colon.
    static func endpoint(_ address: String) -> String {
        address.contains(":") ? "[\(address)]:\(HostLink.hostPort)" : "\(address):\(HostLink.hostPort)"
    }

    /// The text a failed machine records: OpenTofu's diagnostics, or the error itself, plus the
    /// IAM actions when AWS refused for permissions (spec §10's "each failure naming its fix").
    /// Redacted: the diagnostics can quote the user-data's auth key and enrollment secret, and
    /// this text goes to `infra.json`, notifications and the CLI.
    static func failureText(_ error: Error) -> String {
        let text: String
        switch error {
        case TofuError.failed(let step, let message): text = "\(step): \(message)"
        case TofuError.missingOutput(let output): text = "the module has no \(output) output"
        case InfraError.enrollTimeout: text = "the machine did not enroll in time; its console output is in the error"
        case InfraError.enrollFailed: text = "the machine could not install or enroll hostd and powered itself off; its console output is in the error"
        default: text = String(describing: error)
        }
        return SecretRedaction.redact(InfraPreflight.fix(forFailure: text).map { "\(text)\n\($0)" } ?? text)
    }
}
