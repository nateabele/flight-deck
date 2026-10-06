import Foundation
import IntakeKit
import OSLog

/// Persists every swarm and its action log beside `sessions.json`.
///
/// `root` is the same directory `intakes/` lives in — `FileSessionPersistence.defaultDirectory()`,
/// which already separates `Flight Deck` from `Flight Deck (Debug)`, or `-FlightDeckStateDir`. A
/// Debug build writing the live swarms file would resume a release build's swarm from a second
/// app, which is the duplicate-agent collision `AGENTS.md` rule 2 is about.
@MainActor
final class SwarmStore {
    static let restartBanner = "Swarm paused after restart · Resume"
    private static let logger = Logger(subsystem: "dev.flightdeck.FlightDeck", category: "swarm")

    private struct File: Codable { var v: Int; var swarms: [SwarmRecord] }

    let root: URL
    var fileURL: URL { root.appendingPathComponent("swarms.json") }
    var logDirectory: URL { root.appendingPathComponent("swarm-log", isDirectory: true) }

    init(root: URL) { self.root = root }

    static func defaultRoot(stateDirectory: URL?) -> URL {
        stateDirectory ?? FileSessionPersistence.defaultDirectory()
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.sortedKeys]; return e
    }()
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d
    }()

    /// The `v` this build writes and understands.
    static let fileVersion = 1
    private struct Version: Decodable { var v: Int }

    /// Empty on a missing or unreadable file. A corrupt swarms file must never stop the app from
    /// launching — but loading it as empty means the next save overwrites the only copy of every
    /// swarm in it, so an undecodable file, or one a newer build wrote, is first moved aside
    /// beside it and named in the log.
    func load() -> [SwarmRecord] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        if let version = try? Self.decoder.decode(Version.self, from: data), version.v > Self.fileVersion {
            moveAside(as: "v\(version.v)", reason: "was written by a newer Flight Deck (v\(version.v))")
            return []
        }
        guard let file = try? Self.decoder.decode(File.self, from: data) else {
            moveAside(as: "corrupt", reason: "did not decode")
            return []
        }
        return file.swarms
    }

    private func moveAside(as tag: String, reason: String) {
        let aside = root.appendingPathComponent("swarms.json.\(tag)-\(Int(Date().timeIntervalSince1970))")
        do {
            try FileManager.default.moveItem(at: fileURL, to: aside)
            Self.logger.error("swarms.json \(reason, privacy: .public); moved to \(aside.lastPathComponent, privacy: .public), starting with no swarms")
        } catch {
            Self.logger.error("swarms.json \(reason, privacy: .public) and could not be moved aside: \(String(describing: error), privacy: .public)")
        }
    }

    /// `load()` with spec §2's relaunch rule applied: a running or draining swarm comes back
    /// paused with the restart banner. The agents survive in their tabs (fd-abduco); FD does not.
    func restore() -> [SwarmRecord] {
        load().map { record in
            var r = record
            if r.state == .running || r.state == .draining {
                r.state = .paused
                r.banner = Self.restartBanner
            }
            return r
        }
    }

    func save(_ records: [SwarmRecord]) {
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try Self.encoder.encode(File(v: Self.fileVersion, swarms: records)).write(to: fileURL, options: .atomic)
        } catch {
            Self.logger.error("could not save swarms.json: \(String(describing: error), privacy: .public)")
        }
    }

    func append(_ entry: SwarmLogEntry, swarm: UUID) {
        guard var line = try? Self.encoder.encode(entry) else { return }
        line.append(0x0A)
        let url = logDirectory.appendingPathComponent("\(swarm.uuidString).jsonl")
        do {
            try FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: line)
            } else {
                try line.write(to: url)
            }
        } catch {
            Self.logger.error("could not append to \(url.lastPathComponent, privacy: .public)")
        }
    }

    func log(swarm: UUID) -> [SwarmLogEntry] {
        let url = logDirectory.appendingPathComponent("\(swarm.uuidString).jsonl")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { try? Self.decoder.decode(SwarmLogEntry.self, from: Data($0.utf8)) }
    }
}
