import Combine
import Foundation
import HostKit
import OSLog

/// The controller's half of "nothing outlives its TTL" (spec §7.2), plus idle and drift
/// (§7.3) and the running spend caps (§8.2). Once a minute, for every running machine, in this
/// order — the first that destroys the machine ends its pass:
///
/// 1. **Drift**, at most every 10 minutes: an instance its own timer already ended is cleaned up.
/// 2. **TTL**: a warning 10 minutes before the deadline, then destroy at it.
/// 3. **Idle**: hostd's `idleSince`; nil (busy, the macOS hostd, an older hostd, an unreachable
///    host) is never idle.
/// 4. **Budget**: a warning at the threshold, once each; at a cap, destroy after 5 minutes
///    unless the cap was raised meanwhile. `extend` cannot override it.
///
/// It also follows a moving Mac (§6.2): a public-mode machine whose link stays down for 30 s
/// has its firewall re-pointed at this Mac's current public IP.
@MainActor
final class Reaper {
    static let ttlWarning: TimeInterval = 600
    static let budgetGrace: TimeInterval = 300
    static let driftInterval: TimeInterval = 600
    static let linkLostDebounce: TimeInterval = 30

    private let service: InfraService
    private let hosts: HostService
    private let clock: HostLinkClock
    private let notifier: InfraNotifying
    private let budget: () -> BudgetSettings
    private let interval: TimeInterval

    private var started = false
    private var timer: HostLinkCancellable?
    private var ticking = false
    /// A pass asked for while one is running runs right after it rather than being dropped.
    private var tickAgain = false
    private var subscription: AnyCancellable?
    private var offline: Set<UUID> = []
    private var linkTimers: [UUID: HostLinkCancellable] = [:]

    // Per machine, by name. Memory only: after a relaunch a warning is sent again, which is
    // the safe direction, and a budget destroy starts a fresh 5-minute warning.
    private var lastRefresh: [String: Date] = [:]
    /// The deadline each machine was warned about, so an `extend` earns a fresh warning.
    private var ttlWarned: [String: Date] = [:]
    /// `machine:<name>` and `month`: the thresholds already warned about.
    private var budgetWarned: Set<String> = []
    private var budgetDestroyAt: [String: Date] = [:]

    private static let logger = Logger(subsystem: "dev.flightdeck.FlightDeck", category: "infra")

    init(service: InfraService, hosts: HostService, clock: HostLinkClock, notifier: InfraNotifying,
         budget: @escaping () -> BudgetSettings, interval: TimeInterval = 60) {
        self.service = service
        self.hosts = hosts
        self.clock = clock
        self.notifier = notifier
        self.budget = budget
        self.interval = interval
    }

    func start() {
        guard !started else { return }
        started = true
        scheduleTick()
        subscription = hosts.$statuses.sink { [weak self] in self?.statusesChanged($0) }
    }

    func stop() {
        started = false
        timer?.cancel()
        timer = nil
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
        budgetDestroyAt = budgetDestroyAt.filter { names.contains($0.key) }
        for m in service.registry.machines where Self.isRunning(m) {
            await check(m.name)
        }
    }

    private func check(_ name: String) async {
        guard let m = running(name) else { return }

        if lastRefresh[name].map({ clock.now.timeIntervalSince($0) >= Self.driftInterval }) ?? true {
            lastRefresh[name] = clock.now
            if await service.refreshShowsGone(m) {
                await destroy(name, title: "\(name) is gone",
                              body: "Its instance no longer exists (its own timer ended it, or it was deleted outside Flight Deck); Flight Deck cleaned up what was left.")
                return
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

        if m.idle.seconds > 0 {
            // Offline or failing: no answer is not "idle", and the state is left as it was.
            if let info = (try? await hosts.info(name: name))?.1 {
                if let since = info.idleSince {
                    let idleFor = clock.now.timeIntervalSince(since)
                    if idleFor >= TimeInterval(m.idle.seconds) {
                        await destroy(name, title: "\(name) destroyed",
                                      body: "\(name) was idle for \(InfraService.span(idleFor)), past its \(m.idle.formatted) idle limit.")
                        return
                    }
                    service.setIdle(name, true)
                } else {
                    service.setIdle(name, false)
                }
            }
        }

        guard let m = running(name), m.hourlyUSD != nil else { return }
        await checkBudget(m)
    }

    private func checkBudget(_ m: InfraMachine) async {
        let name = m.name, now = clock.now, settings = budget()
        let spent = service.ledger.spent(name: name, now: now)
        let month = service.ledger.monthToDate(now: now)
        // Which threshold is crossed, in `checkRunning`'s own order, so each is warned once
        // and warned again only after spend fell back under it (a raised cap).
        let machineKey = "machine:\(name)"
        let machineWarn = settings.perMachineCapUSD.map { spent >= settings.warnFraction * $0 } ?? false
        let monthWarn = settings.monthlyCapUSD.map { month >= settings.warnFraction * $0 } ?? false
        if !machineWarn { budgetWarned.remove(machineKey) }
        if !monthWarn { budgetWarned.remove("month") }

        switch CostModel.checkRunning(spent: spent, monthToDate: month, settings: settings) {
        case .ok:
            budgetDestroyAt[name] = nil
        case .warn(let why):
            budgetDestroyAt[name] = nil
            if budgetWarned.insert(machineWarn ? machineKey : "month").inserted {
                notifier.notify(id: Self.notificationID(name), title: "\(name) is near its budget", body: why)
            }
        case .destroy(let why):
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
    }

    /// Notifies first, so the user hears why even if the destroy fails, then says so if it did.
    /// A refusal means an `up`, `down` or address change holds the machine right now; the next
    /// pass tries again, so it is not news.
    private func destroy(_ name: String, title: String, body: String) async {
        notifier.notify(id: Self.notificationID(name), title: title, body: body)
        do {
            try await service.down(name: name) { _ in }
            lastRefresh[name] = nil
            ttlWarned[name] = nil
            budgetDestroyAt[name] = nil
            budgetWarned.remove("machine:\(name)")
        } catch InfraError.refused(let why) {
            Self.logger.info("\(name, privacy: .public): destroy deferred: \(why, privacy: .public)")
        } catch {
            Self.logger.error("\(name, privacy: .public): destroy failed: \(String(describing: error), privacy: .public)")
            notifier.notify(id: Self.notificationID(name), title: "Couldn't destroy \(name)",
                            body: "\(InfraService.failureText(error)) Run `flightdeck infra down \(name)`.")
        }
    }

    // MARK: - Public mode follows the Mac (Review Focus 5)

    /// A public-mode machine's link went down: if this Mac's public IP moved, re-point its
    /// firewall there. The link's own backoff redials once the rule is in.
    func linkLost(name: String) async {
        do {
            if let cidr = try await service.followPublicIP(name: name) {
                Self.logger.info("\(name, privacy: .public): firewall now admits \(cidr, privacy: .public)")
            }
        } catch {
            Self.logger.error("\(name, privacy: .public): firewall update failed: \(String(describing: error), privacy: .public)")
            notifier.notify(id: Self.notificationID(name), title: "Couldn't reach \(name)",
                            body: "This Mac's public address changed and \(name)'s firewall could not be updated: \(InfraService.failureText(error))")
        }
    }

    /// Every entry into `.offline` — a drop, or the first status after launch — starts a 30 s
    /// window; coming back inside it cancels the check. A drop is usually a blip, and asking
    /// for the public IP and running `apply` on every one would be both slow and noisy.
    private func statusesChanged(_ statuses: [UUID: HostLinkState]) {
        for (slot, state) in statuses {
            if case .offline = state {
                if offline.insert(slot).inserted { armLinkLost(slot) }
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

    private func armLinkLost(_ slot: UUID) {
        guard machine(slot: slot)?.network == .public else { return }
        linkTimers[slot]?.cancel()
        linkTimers[slot] = clock.schedule(after: Self.linkLostDebounce) { [weak self] in
            guard let self, self.started else { return }
            self.linkTimers[slot] = nil
            guard case .offline = self.hosts.statuses[slot], let m = self.machine(slot: slot) else { return }
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
