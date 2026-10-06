#if DEBUG
import Foundation
import IntakeKit

/// `-FlightControlFixtureBackend <dir>` — Debug builds only, and only with
/// `-FlightDeckResetState` (`FlightDeckApp`). Points `am`/`br` at the stubs
/// `scripts/make-flight-control-fixture.py` built, the swarms root at its `state/`, and routing
/// and capacity at deterministic stand-ins, so SwarmUITests drives the real app with no real
/// br, am, account or agent. Never compiled into Release.
struct FlightControlFixtureBackend {
    let root: URL

    static func fromDefaults(_ defaults: UserDefaults = .standard) -> FlightControlFixtureBackend? {
        guard let path = defaults.string(forKey: "FlightControlFixtureBackend"), !path.isEmpty else { return nil }
        return FlightControlFixtureBackend(root: URL(fileURLWithPath: path, isDirectory: true))
    }

    var tools: FlywheelToolPaths {
        FlywheelToolPaths(am: root.appendingPathComponent("bin/am").path, br: root.appendingPathComponent("bin/br").path)
    }
    var projectPath: String { root.appendingPathComponent("project", isDirectory: true).standardizedFileURL.path }
    var swarmsRoot: URL { root.appendingPathComponent("state", isDirectory: true) }

    private struct Table: Decodable {
        struct Routing: Decodable { let harness: String; let model: String; let pool: String }
        let pools: [String: Int]
        let routing: Routing
    }

    func dependencies() -> SwarmDependencies? {
        guard let data = try? Data(contentsOf: root.appendingPathComponent("swarm-deps.json")),
              let table = try? JSONDecoder().decode(Table.self, from: data) else { return nil }
        let slots = FixtureSlots(pools: table.pools)
        let router = FixtureRouter(harness: HarnessID(table.routing.harness), model: table.routing.model,
                                   pool: PoolID(table.routing.pool))
        return SwarmDependencies(
            makeRouter: { router }, kinds: FixtureKinds(), allocator: slots, capacity: slots,
            pools: FixturePools(harness: router.harness, ids: table.pools.keys.sorted().map { PoolID($0) }))
    }
}

/// Routes every kind to one model and never spills — the UI test asserts on routing it can predict.
final class FixtureRouter: Router, @unchecked Sendable {
    let harness: HarnessID, model: String, pool: PoolID
    init(harness: HarnessID, model: String, pool: PoolID) { self.harness = harness; self.model = model; self.pool = pool }
    func assign(kind: TaskKind, project: URL, catalogs: AdapterCatalogs, now: Date) -> Assignment {
        Assignment(block: ExecutionBlock(kind: kind.id, harness: harness, model: model, pool: pool,
                                         source: AssignmentSource(by: .rule, ruleId: "fixture", reason: "fixture routing", at: now)))
    }
    func spill(_ block: ExecutionBlock, kind: TaskKind, project: URL, exhausted: Set<PoolID>,
               catalogs: AdapterCatalogs, now: Date) -> Assignment? { nil }
}

/// The launch sheet's Override picker offers the fixture's own pools, not `claude-default`.
struct FixturePools: PoolDirectory {
    let harness: HarnessID
    let ids: [PoolID]
    func pools() -> [PoolSummary] { ids.map { PoolSummary(id: $0, harness: harness, label: $0.rawValue) } }
    func defaultPool(for harness: HarnessID) -> PoolID? { harness == self.harness ? ids.first : nil }
}

final class FixtureKinds: KindRegistry, @unchecked Sendable {
    func kinds(project: URL) throws -> [TaskKind] { SeedKinds.all(createdAt: Date(timeIntervalSince1970: 1_791_136_800)) }
    func propose(_ kind: TaskKind, project: URL) throws -> TaskKind { kind }
}

/// Local slots: a pool of N accountless slots, each leased once until released, all under soft.
final class FixtureSlots: PoolAllocator, CapacityReader, @unchecked Sendable {
    private let lock = NSLock()
    private let pools: [String: Int]
    private var taken: [PoolID: Set<Int>] = [:]
    init(pools: [String: Int]) { self.pools = pools }

    private func account(_ index: Int) -> AccountRef { AccountRef(harness: "claude", id: nil, label: "local \(index)") }

    func lease(pool: PoolID) -> AccountLease? {
        lock.withLock {
            guard let count = pools[pool.rawValue], count > 0 else { return nil }
            for index in 1...count where !(taken[pool]?.contains(index) ?? false) {
                taken[pool, default: []].insert(index)
                return AccountLease(pool: pool, account: account(index))
            }
            return nil
        }
    }

    func release(_ lease: AccountLease) {
        lock.withLock {
            if let index = Int(lease.account.label.split(separator: " ").last ?? "") { taken[lease.pool]?.remove(index) }
        }
    }

    func headroom(pool: PoolID) -> [AccountHeadroom] {
        guard let count = pools[pool.rawValue], count > 0 else { return [] }
        return (1...count).map { AccountHeadroom(account: account($0), worstUtilization: 0.3, state: .underSoft, resetsAt: nil) }
    }
}
#endif
