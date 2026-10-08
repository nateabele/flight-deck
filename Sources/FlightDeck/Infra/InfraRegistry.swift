import Foundation
import HostKit

enum InfraState: String, Codable, Sendable { case planned, provisioning, enrolling, ready, idle, destroying, gone, failed, orphaned }
enum NetworkMode: String, Codable, Sendable { case tailnet, `public` }

/// One cloud machine Flight Deck provisioned (or is provisioning). Keyed by `name`, which is
/// also its work directory under the registry's `workRoot`.
struct InfraMachine: Codable, Equatable, Identifiable, Sendable {
    var name: String
    var repoRoot: String
    var cloud: String
    var instanceType: String
    var region: String
    var slot: UUID?
    var state: InfraState
    var failure: String?
    var network: NetworkMode
    var createdAt: Date
    var deadline: Date
    var idle: Duration
    var allowCIDR: String?
    var instanceID: String?
    var address: String?
    var hourlyUSD: Double?
    /// When the machine's own TTL fires: AWS's poweroff timer, GCP's `max_run_duration`. Fixed
    /// at creation, so `deadline` (the controller's) may move later only up to here (plan
    /// deviation 6). Nil in a record written before it existed, which means `deadline`.
    var machineDeadline: Date? = nil
    var id: String { name }
}

/// The cloud machines: `infra.json`, its own file beside `hosts.json`. Spend lives in
/// `CostLedger`'s file instead, so history survives a machine being removed here.
@MainActor
final class InfraRegistry {
    private(set) var machines: [InfraMachine]
    private let file: VersionedJSONFile<InfraMachine>
    private let workRoot: URL

    init(fileURL: URL, workRoot: URL) {
        file = VersionedJSONFile(url: fileURL, key: "machines")
        self.workRoot = workRoot
        machines = file.load()
    }

    /// Replaces the machine of the same name or appends. In-memory state changes only once
    /// the write succeeded, so memory never names a machine the file has not heard of.
    func upsert(_ m: InfraMachine) throws {
        var next = machines
        if let i = next.firstIndex(where: { $0.name == m.name }) { next[i] = m } else { next.append(m) }
        try file.write(next)
        machines = next
    }

    func remove(name: String) throws {
        let next = machines.filter { $0.name != name }
        try file.write(next)
        machines = next
    }

    func machine(named name: String) -> InfraMachine? { machines.first { $0.name == name } }

    func workdir(for name: String) -> URL { workRoot.appendingPathComponent(name, isDirectory: true) }
}
