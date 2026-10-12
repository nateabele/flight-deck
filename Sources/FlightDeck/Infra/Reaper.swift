import Combine
import Foundation
import HostKit
import OSLog

/// The controller's half of "nothing outlives its TTL" (spec §7.2), plus idle and drift
/// (§7.3) and the running spend caps (§8.2). Once a minute, for every running machine, in this
/// order — the first that destroys the machine ends its pass:
///
/// 1. **Drift**, at most every 10 minutes, holding the name: an instance its own timer already
///    ended is cleaned up.
/// 2. **TTL**: a warning 10 minutes before the deadline, then destroy at it.
/// 3. **Idle**: hostd's `idleSince`; nil (busy, the macOS hostd, an older hostd, an unreachable
///    host) is never idle, and idleness is timed on this Mac's clock from when the Reaper first
///    saw that `idleSince`, so a host clock running behind can never reap early.
/// 4. **Budget**: a warning at each threshold (the machine's cap and the month's), once each;
///    at a cap, destroy after 5 minutes unless the cap was raised meanwhile. `extend` cannot
///    override it.
///
/// A machine a `down` left `failed` is destroyed again, backing off 1, 5, 15, then every 30
/// minutes. And it follows a moving Mac (§6.2): a public-mode machine whose link stays down has
/// its firewall re-pointed at this Mac's current public IP, 30 s after the drop, every 3 minutes
/// while it stays down, and on every network path change.
@MainActor
final class Reaper {
    static let ttlWarning: TimeInterval = 600
    static let budgetGrace: TimeInterval = 300
    static let driftInterval: TimeInterval = 600
    static let linkLostDebounce: TimeInterval = 30
    static let linkLostRetry: TimeInterval = 180
    /// The wait after the 1st, 2nd, 3rd failed destroy; every later one waits the last.
    static let destroyBackoff: [TimeInterval] = [60, 300, 900, 1800]

    private let service: InfraService
    private let hosts: HostService
    private let clock: HostLinkClock
    private let notifier: InfraNotifying
    private let budget: () -> BudgetSettings
    private let interval: TimeInterval
    private let pathChanges: (@escaping () -> Void) -> HostLinkCancellable

    private var started = false
    private var timer: HostLinkCancellable?
    private var pathWatch: HostLinkCancellable?
    private var ticking = false
    /// A pass asked for while one is running runs right after it rather than being dropped.
    private var tickAgain = false
    private var subscription: AnyCancellable?
    private var offline: Set<UUID> = []
    private var linkTimers: [UUID: HostLinkCancellable] = [:]

    // Per machine, by name. Memory only: after a relaunch a warning is sent again and idleness
    // is timed afresh, both the safe direction, and a budget destroy starts a fresh 5 minutes.
    private var lastRefresh: [String: Date] = [:]
    /// The deadline each machine was warned about, so an `extend` earns a fresh warning.
    private var ttlWarned: [String: Date] = [:]
    /// The host's `idleSince` and when this Mac first saw it.
    private var idleSeen: [String: (since: Date, firstSeen: Date)] = [:]
    /// `machine:<name>` and `month`: the thresholds already warned about.
    private var budgetWarned: Set<String> = []
    private var budgetDestroyAt: [String: Date] = [:]

    private static let logger = Logger(subsystem: "dev.flightdeck.FlightDeck", category: "infra")

    /// `pathChanges` watches for this Mac's network changing; nil is `NWPathMonitor`'s.
    init(service: InfraService, hosts: HostService, clock: HostLinkClock, notifier: InfraNotifying,
         budget: @escaping () -> BudgetSettings, interval: TimeInterval = 60,
         pathChanges: ((@escaping () -> Void) -> HostLinkCancellable)? = nil) {
        self.service = service
        self.hosts = hosts
        self.clock = clock
        self.notifier = notifier
        self.budget = budget
        self.interval = interval
        self.pathChanges = pathChanges ?? { NetworkHostDialer().watchPath(onChange: $0) }
    }

    func start() {
        guard !started else { return }
        started = true
        scheduleTick()
        subscription = hosts.$statuses.sink { [weak self] in self?.statusesChanged($0) }
        pathWatch = pathChanges { [weak self] in self?.pathChanged() }
    }

    func stop() {
        started = false
        timer?.cancel()
        timer = nil
        pathWatch?.cancel()
        pathWatch = nil
        subscription = nil
        linkTimers.values.forEach { $0.cancel() }
        linkTimers = [:]
        offline = []
    }

    /// The next fire is scheduled before this one's pass runs, so a slow pass (a destroy takes
    /// minutes) never stretches the cadence for every other machine.
    private func scheduleTick() {
        timer = clock.schedule(after: interval) { [weak self] in
            guard let self, self.started else { return }
            self.scheduleTick()
            Task { await self.tick() }
        }
    }

    // MARK: - One pass

    func tick() async {
        guard !ticking else { tickAgain = true; return }
        ticking = true
        defer { ticking = false }
        repeat {
            tickAgain = false
            await pass()
        } while tickAgain
    }

    private func pass() async {
        let names = Set(service.registry.machines.map(\.name))
        lastRefresh = lastRefresh.filter { names.contains($0.key) }
        ttlWarned = ttlWarned.filter { names.contains($0.key) }
        idleSeen = idleSeen.filter { names.contains($0.key) }
        budgetDestroyAt = budgetDestroyAt.filter { names.contains($0.key) }
        for m in service.registry.machines {
            if Self.isRunning(m) {
                await check(m.name)
            } else if m.state == .failed {
                await retryDestroy(m)
            }
        }
    }

    private func check(_ name: String) async {
        if lastRefresh[name].map({ clock.now.timeIntervalSince($0) >= Self.driftInterval }) ?? true {
            // Nil: an `up`, `down` or address change holds the name; look again next pass.
            if let gone = await service.refreshClaimed(name) {
                lastRefresh[name] = clock.now
                if gone {
                    await destroy(name, title: "\(name) is gone",
                                  body: "Its instance no longer exists (its own timer ended it, or it was deleted outside Flight Deck); Flight Deck cleaned up what was left.")
                    return
                }
            }
        }

        // Re-read after every suspension: an `extend`, `down` or another pass may have moved it.
        guard let m = running(name) else { return }
        let left = m.deadline.timeIntervalSince(clock.now)
        if left <= 0 {
            await destroy(name, title: "\(name) destroyed", body: "\(name) reached the end of its TTL.")
            return
        }
        if left <= Self.ttlWarning, ttlWarned[name] != m.deadline {
            ttlWarned[name] = m.deadline
            let minutes = Int((left / 60).rounded(.up))
            notifier.notify(id: Self.notificationID(name), title: "\(name) will be destroyed soon",
                            body: "\(name) reaches its TTL in \(minutes) \(minutes == 1 ? "minute" : "minutes"); `flightdeck infra extend \(name) 1h` keeps it longer.")
        }

        if m.idle.seconds > 0, await idleTooLong(m) {
            await destroy(name, title: "\(name) destroyed",
                          body: "\(name) was idle for its whole \(m.idle.formatted) idle limit.")
            return
        }

        guard let m = running(name), m.hourlyUSD != nil else { return }
        await checkBudget(m)
    }

    /// True once this Mac has seen the same `idleSince` for the machine's whole idle limit. The
    /// host's timestamp is only an identity here, never compared with this Mac's clock: a host
    /// clock 10 minutes behind would otherwise reap 10 minutes early. No answer (offline) is
    /// not "idle" and ends the observation; the state shown is left as it was.
    private func idleTooLong(_ m: InfraMachine) async -> Bool {
        guard let info = (try? await hosts.info(name: m.name))?.1 else {
            idleSeen[m.name] = nil
            return false
        }
        guard let since = info.idleSince else {
            idleSeen[m.name] = nil
            service.setIdle(m.name, false)
            return false
        }
        if idleSeen[m.name]?.since != since { idleSeen[m.name] = (since, clock.now) }
        service.setIdle(m.name, true)
        let seen = idleSeen[m.name].map { clock.now.timeIntervalSince($0.firstSeen) } ?? 0
        return seen >= TimeInterval(m.idle.seconds)
    }

    /// The machine's cap and the month's are checked apart — each with `checkRunning`'s own
    /// words, the other cap cleared — so each threshold is warned about once, independently,
    /// and again only after spend fell back under it (a raised cap).
    private func checkBudget(_ m: InfraMachine) async {
        let name = m.name, now = clock.now, settings = budget()
        var machineOnly = settings, monthOnly = settings
        machineOnly.monthlyCapUSD = nil
        monthOnly.perMachineCapUSD = nil
        let machine = CostModel.checkRunning(spent: service.ledger.spent(name: name, now: now), monthToDate: 0, settings: machineOnly)
        let month = CostModel.checkRunning(spent: 0, monthToDate: service.ledger.monthToDate(now: now), settings: monthOnly)

        for (key, state, id) in [("machine:\(name)", machine, Self.notificationID(name)), ("month", month, "infra.month")] {
            switch state {
            case .ok: budgetWarned.remove(key)
            case .warn(let why):
                if budgetWarned.insert(key).inserted {
                    notifier.notify(id: id, title: key == "month" ? "Cloud spend is near the monthly budget" : "\(name) is near its budget",
                                    body: why)
                }
            case .destroy: budgetWarned.insert(key)
            }
        }

        func overCap(_ state: CostModel.RunningState) -> String? {
            if case .destroy(let why) = state { return why }
            return nil
        }
        guard let why = overCap(machine) ?? overCap(month) else {
            budgetDestroyAt[name] = nil
            return
        }
        guard let at = budgetDestroyAt[name] else {
            budgetDestroyAt[name] = now.addingTimeInterval(Self.budgetGrace)
            notifier.notify(id: Self.notificationID(name), title: "\(name) is over budget",
                            body: "\(why) Flight Deck destroys \(name) in 5 minutes; raising the cap in Settings → Cloud → Budget keeps it.")
            return
        }
        if now >= at {
            await destroy(name, title: "\(name) destroyed", body: "\(why) \(name) was destroyed.")
        }
    }

    /// Notifies first, so the user hears why even if the destroy fails, then says so if it did.
    /// A refusal means an `up`, `down` or address change holds the machine right now; the next
    /// pass tries again, so it is not news. A failure leaves the machine `failed` with its
    /// attempt counted, for `retryDestroy`.
    private func destroy(_ name: String, title: String, body: String) async {
        notifier.notify(id: Self.notificationID(name), title: title, body: body)
        do {
            try await service.down(name: name) { _ in }
            forget(name)
        } catch InfraError.refused(let why) {
            Self.logger.info("\(name, privacy: .public): destroy deferred: \(why, privacy: .public)")
        } catch {
            Self.logger.error("\(name, privacy: .public): destroy failed: \(String(describing: error), privacy: .public)")
            notifier.notify(id: Self.notificationID(name), title: "Couldn't destroy \(name)",
                            body: "\(InfraService.failureText(error)) Flight Deck keeps trying; `flightdeck infra down \(name)` tries now.")
        }
    }

    /// A machine whose `down` failed (by the Reaper or the user) may still be billing, so it is
    /// destroyed again once its backoff has passed. One that failed during `up` was never
    /// destroyed by anyone and has no attempts: that one is the user's to `down`.
    private func retryDestroy(_ m: InfraMachine) async {
        guard let attempts = m.destroyAttempts, attempts > 0, let last = m.lastDestroyAt else { return }
        let wait = Self.destroyBackoff[min(attempts, Self.destroyBackoff.count) - 1]
        guard clock.now.timeIntervalSince(last) >= wait else { return }
        do {
            try await service.down(name: m.name) { _ in }
            forget(m.name)
            notifier.notify(id: Self.notificationID(m.name), title: "\(m.name) destroyed",
                            body: "Destroyed on attempt \(attempts + 1).")
        } catch {
            Self.logger.error("\(m.name, privacy: .public): destroy retry \(attempts + 1) failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func forget(_ name: String) {
        lastRefresh[name] = nil
        ttlWarned[name] = nil
        idleSeen[name] = nil
        budgetDestroyAt[name] = nil
        budgetWarned.remove("machine:\(name)")
    }

    // MARK: - Public mode follows the Mac (Review Focus 5)

    /// A public-mode machine's link went down: if this Mac's public IP moved, re-point its
    /// firewall there. The link's own backoff redials once the rule is in.
    func linkLost(name: String) async {
        do {
            if let cidr = try await service.followPublicIP(name: name) {
                Self.logger.info("\(name, privacy: .public): firewall now admits \(cidr, privacy: .public)")
            }
        } catch InfraError.refused(let why) {
            Self.logger.info("\(name, privacy: .public): firewall check deferred: \(why, privacy: .public)")
        } catch {
            Self.logger.error("\(name, privacy: .public): firewall update failed: \(String(describing: error), privacy: .public)")
            notifier.notify(id: Self.notificationID(name), title: "Couldn't reach \(name)",
                            body: "This Mac's public address may have changed and \(name)'s firewall could not be updated: \(InfraService.failureText(error)) Flight Deck tries again while it stays unreachable.")
        }
    }

    /// Every entry into `.offline` — a drop, or the first status after launch — starts a 30 s
    /// window; coming back inside it cancels the check. A drop is usually a blip, and asking
    /// for the public IP and running `apply` on every one would be both slow and noisy.
    private func statusesChanged(_ statuses: [UUID: HostLinkState]) {
        for (slot, state) in statuses {
            if case .offline = state {
                if offline.insert(slot).inserted { armLinkLost(slot, after: Self.linkLostDebounce) }
            } else {
                offline.remove(slot)
                linkTimers.removeValue(forKey: slot)?.cancel()
            }
        }
        for slot in offline where statuses[slot] == nil {
            offline.remove(slot)
            linkTimers.removeValue(forKey: slot)?.cancel()
        }
    }

    /// Fires, then re-arms every 3 minutes for as long as the link stays down: the first look
    /// can come too early (the new network has no route yet, the lookup fails), and the
    /// address can move again while the link is down.
    private func armLinkLost(_ slot: UUID, after delay: TimeInterval) {
        guard machine(slot: slot)?.network == .public else { return }
        linkTimers[slot]?.cancel()
        linkTimers[slot] = clock.schedule(after: delay) { [weak self] in
            guard let self, self.started else { return }
            self.linkTimers[slot] = nil
            guard case .offline = self.hosts.statuses[slot], let m = self.machine(slot: slot) else { return }
            self.armLinkLost(slot, after: Self.linkLostRetry)
            Task { await self.linkLost(name: m.name) }
        }
    }

    /// This Mac changed networks: every public machine whose link is down checks its firewall
    /// now, rather than at its next 3-minute retry.
    private func pathChanged() {
        guard started else { return }
        for slot in offline {
            guard case .offline = hosts.statuses[slot], let m = machine(slot: slot), m.network == .public else { continue }
            Task { await self.linkLost(name: m.name) }
        }
    }

    // MARK: - Plumbing

    private func machine(slot: UUID) -> InfraMachine? { service.registry.machines.first { $0.slot == slot } }

    private func running(_ name: String) -> InfraMachine? {
        service.registry.machine(named: name).flatMap { Self.isRunning($0) ? $0 : nil }
    }

    private static func isRunning(_ m: InfraMachine) -> Bool { m.state == .ready || m.state == .idle }

    /// One banner per machine: each notification about it replaces the last.
    private static func notificationID(_ name: String) -> String { "infra.\(name)" }
}
