import FleetKit
import Foundation
import HostKit
import os

/// One delegated run or service, as the app remembers it (spec §6). Codable because
/// `RunRegistry` writes every one to `delegation.json`: a service outlives an app relaunch on
/// the host, and a registry that forgot it would leave `flightdeck down` with nothing to name,
/// and the service running until `orphan_timeout`.
struct DelegatedRun: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case run, service }
    /// The wire's `WireDelegateRunRow.state` spellings, verbatim.
    enum State: String, Codable, Sendable {
        case queued, running, exited, died
        var isFinished: Bool { self == .exited || self == .died }
    }

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

    init(id: String, hostRunID: String, host: String, owner: UUID?, kind: Kind, command: String, recipe: String?,
         state: State, status: Int32?, ports: [String], startedAt: Date, worktree: String, snapshot: SnapshotRef?,
         applyMode: ApplyMode, request: WireDelegateRun, resultCommit: String?, resultBundle: String?) {
        self.id = id
        self.hostRunID = hostRunID
        self.host = host
        self.owner = owner
        self.kind = kind
        self.command = command
        self.recipe = recipe
        self.state = state
        self.status = status
        self.ports = ports
        self.startedAt = startedAt
        self.worktree = worktree
        self.snapshot = snapshot
        self.applyMode = applyMode
        self.request = request
        self.resultCommit = resultCommit
        self.resultBundle = resultBundle
    }

    enum CodingKeys: String, CodingKey {
        case id, hostRunID, host, owner, kind, command, recipe, state, status, ports, startedAt, worktree
        case snapshot, applyMode, request, include, fetch, resultCommit, resultBundle, endedAt
    }

    /// `include` and `fetch` came after the first file was written: absent reads as none, so
    /// an older `delegation.json` still loads rather than being set aside as corrupt.
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(String.self, forKey: .id), hostRunID: try c.decode(String.self, forKey: .hostRunID),
                  host: try c.decode(String.self, forKey: .host), owner: try c.decodeIfPresent(UUID.self, forKey: .owner),
                  kind: try c.decode(Kind.self, forKey: .kind), command: try c.decode(String.self, forKey: .command),
                  recipe: try c.decodeIfPresent(String.self, forKey: .recipe), state: try c.decode(State.self, forKey: .state),
                  status: try c.decodeIfPresent(Int32.self, forKey: .status), ports: try c.decode([String].self, forKey: .ports),
                  startedAt: try c.decode(Date.self, forKey: .startedAt), worktree: try c.decode(String.self, forKey: .worktree),
                  snapshot: try c.decodeIfPresent(SnapshotRef.self, forKey: .snapshot),
                  applyMode: try c.decode(ApplyMode.self, forKey: .applyMode),
                  request: try c.decode(WireDelegateRun.self, forKey: .request),
                  resultCommit: try c.decodeIfPresent(String.self, forKey: .resultCommit),
                  resultBundle: try c.decodeIfPresent(String.self, forKey: .resultBundle))
        include = try c.decodeIfPresent([String].self, forKey: .include) ?? []
        fetch = try c.decodeIfPresent([String].self, forKey: .fetch) ?? []
        endedAt = try c.decodeIfPresent(Date.self, forKey: .endedAt)
    }
    /// The result commit and the bundle holding it, once fetched and until applied. Nil when
    /// the run changed nothing, or before it ended.
    var resultCommit: String?
    var resultBundle: String?
    /// When this Mac learned it ended, for retention: a service that ran for a month must not
    /// lose its logs the moment it stops. Nil while running, and in a file from before it existed.
    var endedAt: Date?

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
///
/// **Saves are coalesced and written off the main actor.** Every state change saves, and the
/// whole file is rewritten each time: measured at 11 ms a save with 1k runs and 111 ms with
/// 10k, all on main. So a change only marks the registry dirty; one write per `saveDelay`
/// window carries every change made in it, encoded and written on a serial queue (in order,
/// so an older snapshot can never land over a newer one). `flush()` writes now, for app quit.
/// Retention (`expired`) keeps the file from growing without bound in the first place.
@MainActor
final class RunRegistry {
    nonisolated private static let logger = Logger(subsystem: "dev.flightdeck.FlightDeck", category: "delegation")

    /// Finished runs are kept this long after they end, for `logs`, `diff` and `apply`.
    static let retention: TimeInterval = 14 * 24 * 3600
    /// And at most this many finished runs per host, newest first, however recent.
    static let retainedPerHost = 500

    private struct Stored: Codable, Sendable {
        var next: Int
        var runs: [DelegatedRun]
    }

    private let file: URL?
    private var stored: Stored
    /// How long a change waits for others to share its write.
    private let saveDelay: TimeInterval
    private var saveScheduled = false
    /// Writes handed to the queue, for the tests that pin the coalescing.
    private(set) var writes = 0
    private let writer = DispatchQueue(label: "dev.flightdeck.delegation.registry", qos: .utility)

    /// `file` nil keeps everything in memory, for the tests that are not about persistence.
    /// A file that is missing or unreadable starts empty rather than failing the app's launch:
    /// what is lost is the ability to `down` a service by name, which `orphan_timeout` on the
    /// host still covers.
    init(file: URL?, saveDelay: TimeInterval = 0.25) {
        self.file = file
        self.saveDelay = saveDelay
        stored = Stored(next: 1, runs: [])
        guard let file, let data = try? Data(contentsOf: file) else { return }
        var salvaged = 0
        do {
            stored = try JSONDecoder().decode(Stored.self, from: data)
        } catch {
            // The ids it named may still be in a CLI's scrollback (`flightdeck wait r12`):
            // fresh ids start above every one still legible, so none is handed out twice.
            salvaged = Self.highestID(in: String(decoding: data, as: UTF8.self))
            // Moved aside rather than overwritten by the next save: it is the only record of
            // which services are running, and someone may want to read it back by hand.
            let aside = file.appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970))")
            try? FileManager.default.moveItem(at: file, to: aside)
            Self.logger.error("delegation.json unreadable, moved to \(aside.lastPathComponent, privacy: .public)")
        }
        // Above every id on record, whatever the counter says: a hand-edited or half-written
        // file must not let `mintID` hand out an id that already names a run.
        let highest = max(salvaged, stored.runs.compactMap { Int($0.id.dropFirst()) }.max() ?? 0)
        stored.next = max(stored.next, highest + 1)
    }

    /// The highest `"id":"rN"` (or `"next":N - 1`) readable in damaged text.
    static func highestID(in text: String) -> Int {
        let ids = text.matches(of: #/"id"\s*:\s*"r(\d+)"/#).compactMap { Int($0.1) }
        let next = text.matches(of: #/"next"\s*:\s*(\d+)/#).compactMap { Int($0.1).map { $0 - 1 } }
        return (ids + next).max() ?? 0
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

    /// Changes a run; the moment it first reads as finished is stamped as its end.
    func update(_ id: String, _ change: (inout DelegatedRun) -> Void) {
        guard let index = stored.runs.firstIndex(where: { $0.id == id }) else { return }
        change(&stored.runs[index])
        if stored.runs[index].state.isFinished, stored.runs[index].endedAt == nil { stored.runs[index].endedAt = Date() }
        save()
    }

    /// Forgets runs. Their copies on disk are `DelegationService.prune`'s to delete.
    func remove(_ ids: Set<String>) {
        guard !ids.isEmpty else { return }
        stored.runs.removeAll { ids.contains($0.id) }
        save()
    }

    /// The finished runs retention lets go: ended over `retention` ago, or past the newest
    /// `retainedPerHost` finished ones on their host. A run still going is never one of them.
    /// A finished run from before `endedAt` existed counts from its start.
    func expired(now: Date = Date()) -> [DelegatedRun] {
        let finished = stored.runs.filter(\.state.isFinished)
        var expired = Set(finished.filter { now.timeIntervalSince($0.endedAt ?? $0.startedAt) > Self.retention }.map(\.id))
        for runs in Dictionary(grouping: finished, by: \.host).values where runs.count > Self.retainedPerHost {
            let newestFirst = runs.sorted { ($0.endedAt ?? $0.startedAt) > ($1.endedAt ?? $1.startedAt) }
            expired.formUnion(newestFirst.dropFirst(Self.retainedPerHost).map(\.id))
        }
        return stored.runs.filter { expired.contains($0.id) }
    }

    /// Writes now, and waits for it: for app quit, where a save still waiting out its delay
    /// would otherwise be lost with the process.
    func flush() {
        guard let file else { return }
        saveScheduled = false
        let snapshot = stored
        writes += 1
        writer.sync { Self.write(snapshot, to: file) }
    }

    private func save() {
        guard file != nil, !saveScheduled else { return }
        saveScheduled = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64((self?.saveDelay ?? 0) * 1e9))
            guard let self, self.saveScheduled, let file = self.file else { return }
            self.saveScheduled = false
            let snapshot = self.stored
            self.writes += 1
            self.writer.async { Self.write(snapshot, to: file) }
        }
    }

    private nonisolated static func write(_ stored: Stored, to file: URL) {
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(stored).write(to: file, options: .atomic)
        } catch {
            logger.error("could not save delegation.json: \(error.localizedDescription, privacy: .public)")
        }
    }
}
