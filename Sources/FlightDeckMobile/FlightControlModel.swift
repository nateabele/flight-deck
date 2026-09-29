import FleetKit
import Foundation

/// The phone's Flight Control state beside the fleet: known summaries for banner transitions,
/// the banner queue, open intakes' detail models, and a small plan cache (spec §7).
@MainActor
@Observable
final class FlightControlModel {
    static let planCacheLimit = 4
    private(set) var banners: [IntakeBanner] = []
    /// The intake whose screen is on top; its banner is suppressed.
    var onScreen: UUID?
    @ObservationIgnored private var known: [UUID: WireIntakeSummary] = [:]
    @ObservationIgnored private var details: [UUID: IntakeDetailModel] = [:]
    @ObservationIgnored private var plans: [String: WireIntakePlan] = [:]
    @ObservationIgnored private var planOrder: [String] = []
    @ObservationIgnored private weak var fetcher: IntakeFetching?

    init(fetcher: IntakeFetching) { self.fetcher = fetcher }

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

    func dismissBanner(_ id: UUID) { banners.removeAll { $0.id == id } }

    func detailModel(for id: UUID) -> IntakeDetailModel {
        if let m = details[id] { return m }
        let m = IntakeDetailModel(id: id, fetcher: fetcher!)
        details[id] = m
        return m
    }

    /// Checkpoint plans are immutable enough to cache (key: intake, checkpoint, changes); a head
    /// request (`checkpoint == nil`) is never served from cache because the head moves, but its
    /// answer refreshes the entry for the checkpoint it turned out to be.
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
