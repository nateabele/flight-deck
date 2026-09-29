import FleetKit
import Foundation

/// The phone's Flight Control state beside the fleet: known summaries for banner transitions,
/// the banner queue, open intakes' detail models, and a small plan cache (spec §7).
@MainActor
@Observable
final class FlightControlModel {
    static let planCacheLimit = 4
    private(set) var banners: [IntakeBanner] = []
    /// The intake whose screens are on top (the most recent to appear); its banner is
    /// suppressed. Derived from `enter`/`leave`, never assigned.
    private(set) var onScreen: UUID?
    /// Mac clock − phone clock, from the most recent detail any intake screen fetched. The
    /// Sessions list has no detail of its own to learn it from, and a row counting with 0 while
    /// the intake screen counts with the real skew shows two different times for one clock.
    private(set) var macClockOffset: TimeInterval = 0
    @ObservationIgnored private var presence: [UUID: Int] = [:]
    @ObservationIgnored private var entered: [UUID] = []
    @ObservationIgnored private var known: [UUID: WireIntakeSummary] = [:]
    @ObservationIgnored private var details: [UUID: IntakeDetailModel] = [:]
    @ObservationIgnored private var plans: [String: WireIntakePlan] = [:]
    @ObservationIgnored private var planOrder: [String] = []
    @ObservationIgnored private weak var fetcher: IntakeFetching?
    @ObservationIgnored private let receivedAt: () -> Date

    init(fetcher: IntakeFetching, receivedAt: @escaping () -> Date = Date.init) {
        self.fetcher = fetcher
        self.receivedAt = receivedAt
    }

    /// One of an intake's screens appeared. Counted, because a pushed child can appear before
    /// its parent disappears.
    func enter(_ id: UUID) {
        presence[id, default: 0] += 1
        entered.removeAll { $0 == id }
        entered.append(id)
        onScreen = entered.last
    }

    func leave(_ id: UUID) {
        guard let count = presence[id] else { return }
        if count > 1 { presence[id] = count - 1 } else { presence[id] = nil; entered.removeAll { $0 == id } }
        onScreen = entered.last
    }

    /// A snapshot (connect, resync): learn everything, announce nothing (Review Focus #3).
    func baseline(_ fleet: FleetSnapshot) {
        known = [:]
        for project in fleet.projects { for s in project.intakes ?? [] { known[s.id] = s } }
    }

    /// A live `project.intakes` event, heard after the connector folded it into `fleet`.
    func intakesChanged(project: UUID, intakes: [WireIntakeSummary]?, fleet: FleetSnapshot) {
        let name = fleet.projects.first { $0.id == project }?.name ?? ""
        let fresh = BannerPolicy.banners(previous: known, next: intakes ?? [], project: name, onScreen: onScreen)
        for s in intakes ?? [] { known[s.id] = s }
        banners.removeAll { b in fresh.contains { $0.id == b.id } }
        banners.append(contentsOf: fresh)
    }

    /// Forget everything learned from one pairing (unpair): queued banners, the on-screen
    /// suppression, the last-seen intakes and cached detail/plan bodies. Intake content is this
    /// pairing's, and a stale `known` would let the next Mac's first snapshot diff against it.
    func reset() {
        banners = []
        presence = [:]
        entered = []
        onScreen = nil
        known = [:]
        details = [:]
        plans = [:]
        planOrder = []
    }

    func dismissBanner(_ id: UUID) { banners.removeAll { $0.id == id } }

    func detailModel(for id: UUID) -> IntakeDetailModel {
        if let m = details[id] { return m }
        let m = IntakeDetailModel(id: id, fetcher: fetcher!, receivedAt: receivedAt) { [weak self] offset in
            self?.macClockOffset = offset
        }
        details[id] = m
        return m
    }

    /// Contract: the HEAD is always requested with `checkpoint: nil`, never looked up in the cache,
    /// and its reply overwrites the cached entry for the checkpoint it turned out to be. Mac-side
    /// plan edits land at the head, and an explicit-checkpoint key cannot revalidate (the phone
    /// learns `editsVersion` only from a reply), so explicit checkpoints are for older rounds,
    /// whose plans do not change, and stay cached (LRU, `planCacheLimit`).
    func plan(_ intake: UUID, checkpoint: Int?, changes: Bool,
              then completion: @escaping (Result<WireIntakePlan, FleetRequestError>) -> Void) {
        let key = checkpoint.map { "\(intake)/\($0)/\(changes)" }
        if let key, let cached = plans[key] {
            planOrder.removeAll { $0 == key }; planOrder.append(key)
            return completion(.success(cached))
        }
        guard let fetcher else { return completion(.failure(.disconnected)) }
        fetcher.intakePlan(intake, checkpoint: checkpoint, changes: changes) { [weak self] result in
            if let self, case .success(let plan) = result {
                let stored = key ?? "\(intake)/\(plan.checkpoint)/\(changes)"
                self.plans[stored] = plan
                self.planOrder.removeAll { $0 == stored }; self.planOrder.append(stored)
                while self.planOrder.count > Self.planCacheLimit { self.plans.removeValue(forKey: self.planOrder.removeFirst()) }
            }
            completion(result)
        }
    }
}
