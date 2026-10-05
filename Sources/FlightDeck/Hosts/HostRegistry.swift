import FleetKit
import Foundation
import OSLog

/// The paired hosts: `hosts.json` for what they are, `HostSecretStoring` for their keys.
///
/// Its own file beside `sessions.json`, never inside it — a session snapshot is rewritten on
/// every tab change, and a host list that rode along would be one bad decode away from
/// un-pairing every host.
@MainActor
final class HostRegistry {
    private(set) var hosts: [HostRecord]
    /// Exposed so `HostService` can read keys off the main thread at launch.
    nonisolated let secrets: HostSecretStoring
    private let fileURL: URL

    private static let logger = Logger(subsystem: "dev.flightdeck.FlightDeck", category: "hosts")

    /// The file's shape. Versioned so a later field that cannot be read optionally has
    /// somewhere to say so.
    private struct File: Codable {
        var version = 1
        var hosts: [HostRecord]
    }

    init(fileURL: URL, secrets: HostSecretStoring) {
        self.fileURL = fileURL
        self.secrets = secrets
        hosts = Self.load(fileURL)
    }

    /// Stores `key` and a record for it. The secret is written first and removed again if the
    /// file write fails, so neither store ever names a host the other has never heard of.
    @discardableResult
    func add(key: FleetDeviceKey, name: String, serviceName: String,
             endpoints: [String]) throws -> HostRecord {
        let record = HostRecord(
            slot: key.slot, name: uniqueName(name), serviceName: serviceName,
            endpoints: Array(endpoints.prefix(PairingPayload.maxEndpoints)),
            platform: nil, pairedAt: Date())
        try secrets.set(key.secret, for: key.slot)
        do {
            try write(hosts + [record])
        } catch {
            secrets.remove(slot: key.slot)
            throw error
        }
        hosts.append(record)
        return record
    }

    func remove(slot: UUID) {
        secrets.remove(slot: slot)
        hosts.removeAll { $0.slot == slot }
        persist()
    }

    /// Replaces the record with `r`'s slot; a slot that is no longer paired is ignored, so a
    /// late update from a link being forgotten cannot resurrect it.
    func update(_ r: HostRecord) {
        guard let index = hosts.firstIndex(where: { $0.slot == r.slot }), hosts[index] != r
        else { return }
        hosts[index] = r
        persist()
    }

    func key(for slot: UUID) -> FleetDeviceKey? {
        secrets.secret(for: slot).map { FleetDeviceKey(slot: slot, secret: $0) }
    }

    /// Exact, case-insensitive. Never a prefix or a best guess: a CLI that picked "mini-2"
    /// for "mini" would run work on the wrong machine.
    func resolve(name: String) -> Result<HostRecord, HostLookupError> {
        guard let record = hosts.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame })
        else { return .failure(.unknown(available: hosts.map(\.name))) }
        return .success(record)
    }

    /// "mini", then "mini-2", "mini-3"… Two hosts can share a Mac name (two Macs both named
    /// after their owner), and the CLI addresses hosts by name alone.
    private func uniqueName(_ proposed: String) -> String {
        let base = proposed.trimmingCharacters(in: .whitespacesAndNewlines)
        let stem = base.isEmpty ? "host" : base
        let taken = Set(hosts.map { $0.name.lowercased() })
        guard taken.contains(stem.lowercased()) else { return stem }
        var n = 2
        while taken.contains("\(stem)-\(n)".lowercased()) { n += 1 }
        return "\(stem)-\(n)"
    }

    private func persist() {
        do { try write(hosts) } catch {
            Self.logger.error("hosts.json write failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func write(_ records: [HostRecord]) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(File(hosts: records)).write(to: fileURL, options: .atomic)
    }

    /// A missing file is no hosts. An unreadable one is moved aside rather than treated as
    /// empty, because the next `add` would otherwise overwrite it and un-pair every host on
    /// it for good (the hole Task 4 closed in the hostd's `ControllerStore`).
    private static func load(_ url: URL) -> [HostRecord] {
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
        do {
            return try decoder.decode(File.self, from: data).hosts
        } catch {
            moveAside(url, error)
            return []
        }
    }

    private static func moveAside(_ url: URL, _ error: Error) {
        let aside = url.appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970))")
        logger.error("hosts.json unreadable (\(String(describing: error), privacy: .public)); moving to \(aside.lastPathComponent, privacy: .public)")
        try? FileManager.default.moveItem(at: url, to: aside)
    }
}
