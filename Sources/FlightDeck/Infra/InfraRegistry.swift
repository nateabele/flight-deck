import Foundation
import HostKit
import OSLog

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
    var id: String { name }
}

/// The cloud machines: `infra.json`, its own file beside `hosts.json`. Spend lives in
/// `CostLedger`'s file instead, so history survives a machine being removed here.
@MainActor
final class InfraRegistry {
    private(set) var machines: [InfraMachine]
    private let fileURL: URL
    private let workRoot: URL

    private static let logger = Logger(subsystem: "dev.flightdeck.FlightDeck", category: "infra")

    /// Versioned so a later field that cannot be read optionally has somewhere to say so.
    private struct File: Codable {
        var version = 1
        var machines: [InfraMachine]
    }

    init(fileURL: URL, workRoot: URL) {
        self.fileURL = fileURL
        self.workRoot = workRoot
        machines = Self.load(fileURL)
    }

    /// Replaces the machine of the same name or appends. In-memory state changes only once
    /// the write succeeded, so memory never names a machine the file has not heard of.
    func upsert(_ m: InfraMachine) throws {
        var next = machines
        if let i = next.firstIndex(where: { $0.name == m.name }) { next[i] = m } else { next.append(m) }
        try write(next)
        machines = next
    }

    func remove(name: String) throws {
        let next = machines.filter { $0.name != name }
        try write(next)
        machines = next
    }

    func machine(named name: String) -> InfraMachine? { machines.first { $0.name == name } }

    func workdir(for name: String) -> URL { workRoot.appendingPathComponent(name, isDirectory: true) }

    private func write(_ machines: [InfraMachine]) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(File(machines: machines)).write(to: fileURL, options: .atomic)
    }

    /// A missing file is no machines. An unreadable one is moved aside rather than treated as
    /// empty: the next `upsert` would otherwise overwrite it and orphan billing machines.
    private static func load(_ url: URL) -> [InfraMachine] {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch CocoaError.fileReadNoSuchFile {
            return []
        } catch {
            moveAside(url, error)
            return []
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do { return try decoder.decode(File.self, from: data).machines } catch {
            moveAside(url, error)
            return []
        }
    }

    private static func moveAside(_ url: URL, _ error: Error) {
        let aside = url.deletingPathExtension().appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970)).json")
        try? FileManager.default.moveItem(at: url, to: aside)
        logger.error("infra.json unreadable, moved aside: \(String(describing: error), privacy: .public)")
    }
}
