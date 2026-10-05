import FleetKit
import Foundation
import HostKit
import os

/// One delegated run or service, as the app remembers it (spec §6). Codable because
/// `RunRegistry` writes every one to `delegation.json`: a service outlives an app relaunch on
/// the host, and a registry that forgot it would leave `flightdeck down` with nothing to name,
/// and the service running until `orphan_timeout`.
struct DelegatedRun: Codable, Equatable {
    enum Kind: String, Codable { case run, service }
    /// The wire's `WireDelegateRunRow.state` spellings, verbatim.
    enum State: String, Codable { case queued, running, exited, died }

    /// The id the CLI uses: `r` plus a number this Mac never reuses. Local rather than the
    /// host's own id so it is short enough to type, and so `flightdeck wait r7` can be told
    /// apart from `flightdeck wait <session> --for idle` by its shape alone.
    let id: String
    /// What the host calls it, for every request that crosses to it.
    let hostRunID: String
    let host: String
    /// The tab whose token started it, or nil for a human shell (which owns nothing and sees
    /// everything).
    let owner: UUID?
    let kind: Kind
    /// The command as run: a recipe's `run` plus extra args, or the joined argv.
    let command: String
    let recipe: String?
    var state: State
    /// The CLI's exit status once it ended: the code, or 128+signal.
    var status: Int32?
    /// Forwards in `L:R` notation with `L` resolved.
    var ports: [String]
    let startedAt: Date
    /// The local worktree it was synced from, which `apply` merges into and artifacts land in.
    let worktree: String
    /// The snapshot it ran on: the merge base for `apply`. Nil for `exec`, which syncs nothing
    /// and so brings nothing back.
    let snapshot: SnapshotRef?
    let applyMode: ApplyMode
    /// The request that started it, kept so `restart` can start the same thing again.
    let request: WireDelegateRun
    /// The resolved `include` (project + `--include`) and `fetch` (recipe + `--fetch`), kept
    /// so a watcher restarted after a relaunch fetches the same artifacts and hints the same.
    var include: [String] = []
    var fetch: [String] = []
    /// The result commit and the bundle holding it, once fetched and until applied. Nil when
    /// the run changed nothing, or before it ended.
    var resultCommit: String?
    var resultBundle: String?

    var row: WireDelegateRunRow {
        WireDelegateRunRow(runID: id, host: host, command: command, recipe: recipe, kind: kind.rawValue,
                           state: state.rawValue, status: status, ports: ports, startedAt: startedAt)
    }

    /// Whether `caller` may see or act on this run. A human shell (`nil`) sees every run; a
    /// tab sees only its own, so one agent's `stop r7` cannot cancel another tab's build.
    func isVisible(to caller: UUID?) -> Bool {
        guard let caller else { return true }
        return owner == caller
    }
}

/// The app's delegated runs and services, persisted to `delegation.json` beside
/// `sessions.json`. Plain value storage: `DelegationService` decides what the runs mean.
@MainActor
final class RunRegistry {
    private static let logger = Logger(subsystem: "dev.flightdeck.FlightDeck", category: "delegation")

    private struct Stored: Codable {
        var next: Int
        var runs: [DelegatedRun]
    }

    private let file: URL?
    private var stored: Stored

    /// `file` nil keeps everything in memory, for the tests that are not about persistence.
    /// A file that is missing or unreadable starts empty rather than failing the app's launch:
    /// what is lost is the ability to `down` a service by name, which `orphan_timeout` on the
    /// host still covers.
    init(file: URL?) {
        self.file = file
        stored = Stored(next: 1, runs: [])
        guard let file, let data = try? Data(contentsOf: file) else { return }
        do {
            stored = try JSONDecoder().decode(Stored.self, from: data)
        } catch {
            // Moved aside rather than overwritten by the next save: it is the only record of
            // which services are running, and someone may want to read it back by hand.
            let aside = file.appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970))")
            try? FileManager.default.moveItem(at: file, to: aside)
            Self.logger.error("delegation.json unreadable, moved to \(aside.lastPathComponent, privacy: .public)")
        }
        // Above every id on record, whatever the counter says: a hand-edited or half-written
        // file must not let `mintID` hand out an id that already names a run.
        let highest = stored.runs.compactMap { Int($0.id.dropFirst()) }.max() ?? 0
        stored.next = max(stored.next, highest + 1)
    }

    var runs: [DelegatedRun] { stored.runs }

    /// A fresh local id. Persisted with the counter so an id is never reused across a relaunch:
    /// a reused `r3` would let an old `flightdeck wait r3` attach to a stranger's run.
    func mintID() -> String {
        defer { stored.next += 1; save() }
        return "r\(stored.next)"
    }

    func add(_ run: DelegatedRun) {
        stored.runs.append(run)
        save()
    }

    func run(_ id: String) -> DelegatedRun? { stored.runs.first { $0.id == id } }

    func update(_ id: String, _ change: (inout DelegatedRun) -> Void) {
        guard let index = stored.runs.firstIndex(where: { $0.id == id }) else { return }
        change(&stored.runs[index])
        save()
    }

    private func save() {
        guard let file else { return }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(stored).write(to: file, options: .atomic)
        } catch {
            Self.logger.error("could not save delegation.json: \(error.localizedDescription, privacy: .public)")
        }
    }
}
