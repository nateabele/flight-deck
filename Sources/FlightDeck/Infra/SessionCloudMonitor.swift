import FleetKit
import Foundation

/// Keeps `SessionStore.sessionClouds` (and so the sidebar's cloud icon and a phone's cloud pane)
/// in step with what `InfraService` knows: which machines each session owns, what they have
/// cost, and where its budget stands.
///
/// `InfraService` is not observable, so this polls it, as the Cloud settings tab does: every
/// 5 s, and at once when an `infra.*` request finishes (`InfraService.onOperationFinished`).
/// Polling is cheap because a tick with no machine does nothing, and quiet on the wire because
/// of `resend`: spend grows every second, but it travels as a baseline and a rate
/// (`WireSessionCloud`), so a session's summary is re-sent only when its structure changes or
/// its baseline has gone stale.
@MainActor
final class SessionCloudMonitor {
    static let interval: TimeInterval = 5
    /// How old a running session's baseline may get before it is re-sent: a client extrapolates
    /// at the rate it was told, so a rate that has since changed (a machine reaching its
    /// deadline) is corrected at least this often.
    static let reanchorAfter: TimeInterval = 300

    private let service: InfraService
    private let store: SessionStore
    private let clock: HostLinkClock
    private var timer: HostLinkCancellable?

    init(service: InfraService, store: SessionStore, clock: HostLinkClock = SystemHostLinkClock()) {
        self.service = service
        self.store = store
        self.clock = clock
    }

    func start() {
        guard timer == nil else { return }
        service.onOperationFinished = { [weak self] in self?.refresh() }
        schedule()
        refresh()
    }

    func stop() {
        timer?.cancel()
        timer = nil
        service.onOperationFinished = nil
    }

    private func schedule() {
        timer = clock.schedule(after: Self.interval) { [weak self] in
            guard let self, self.timer != nil else { return }
            self.schedule()
            self.refresh()
        }
    }

    /// One pass: rebuild every session's summary and record what `resend` lets through.
    func refresh() {
        // Nothing to compute, and nothing recorded to clear: the common case on a Mac without
        // cloud machines costs one array check per tick.
        guard !service.registry.machines.isEmpty || !store.sessionClouds.isEmpty else { return }
        let now = service.now
        let next = Self.resend(previous: store.sessionClouds, built: service.sessionClouds(now: now), now: now)
        store.recordSessionClouds(next)
    }

    // MARK: - Re-send policy

    /// What to record given what was `previous`ly recorded and what `built` says now. Pure.
    ///
    /// A session keeps its previous value unless its `structure` differs, or the previous
    /// baseline is `reanchorAfter` old while money is still being spent (then the new value
    /// re-anchors it). A session absent from `built` has lost its machines: removed.
    nonisolated static func resend(previous: [UUID: WireSessionCloud], built: [UUID: WireSessionCloud],
                                   now: Date, reanchorAfter: TimeInterval = reanchorAfter) -> [UUID: WireSessionCloud] {
        built.reduce(into: [:]) { next, entry in
            let (id, fresh) = entry
            guard let old = previous[id] else { return next[id] = fresh }
            let stale = old.hourlyUsd > 0 && now.timeIntervalSince(old.asOf) >= reanchorAfter
            next[id] = (!stale && sameStructure(old, fresh)) ? old : fresh
        }
    }

    /// `structure` equality, minus two figures that drift without anything having changed:
    /// the exhaustion instant (a sum over deadlines in floating point, within a few seconds
    /// of the last one; and `now` itself, tick after tick, once the budget is used up).
    nonisolated private static func sameStructure(_ old: WireSessionCloud, _ fresh: WireSessionCloud) -> Bool {
        var a = old.structure, b = fresh.structure
        if let x = old.budgetExhaustsAt, let y = fresh.budgetExhaustsAt {
            let oldUsedUp = x <= old.asOf, freshUsedUp = y <= fresh.asOf
            if oldUsedUp == freshUsedUp, oldUsedUp || abs(x.timeIntervalSince(y)) < 30 {
                a.budgetExhaustsAt = nil
                b.budgetExhaustsAt = nil
            }
        }
        return a == b
    }
}

extension InfraService {
    /// Every session that owns a machine that still exists, as `WireSessionCloud`: machines
    /// oldest first, per-machine spend from the ledger, the session's spend, rate and
    /// exhaustion from `sessionStatus`, and this month's spend for the whole Mac.
    func sessionClouds(now: Date) -> [UUID: WireSessionCloud] {
        let month = ledger.monthToDate(now: now), monthCap = monthlyCapUSD
        let owned = registry.machines.filter { $0.state != .gone && $0.session != nil }
            .sorted { $0.createdAt < $1.createdAt }
        return Dictionary(grouping: owned) { $0.session! }.mapValues { machines in
            let session = machines[0].session!
            let status = sessionStatus(session, now: now)
            return WireSessionCloud(
                asOf: now,
                machines: machines.map { m in
                    WireCloudMachine(
                        name: m.name, cloud: m.cloud, instanceType: m.instanceType, region: m.region,
                        state: m.state.rawValue, network: m.network.rawValue, hourlyUsd: m.hourlyUSD,
                        spentUsd: ledger.spent(name: m.name, now: now), createdAt: m.createdAt, deadline: m.deadline,
                        machineDeadline: m.machineDeadline, failure: m.failure.map(SecretRedaction.redact))
                },
                spentUsd: status.spent,
                // Rounded: a sum over a dictionary's values may differ in its last bits from
                // one tick to the next, and that must not read as a changed rate.
                hourlyUsd: (status.hourly * 1e6).rounded() / 1e6,
                budgetCapUsd: status.budget?.capUSD, budgetSince: status.budget?.since,
                budgetExhaustsAt: status.exhaustsAt,
                monthUsd: month, monthCapUsd: monthCap)
        }
    }
}
