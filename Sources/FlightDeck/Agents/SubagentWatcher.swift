import FleetKit
import Foundation

/// Keeps one conversation's `SubagentTree` current from its `subagents/` folder.
///
/// **A steady tick touches only live files.** A conversation can hold hundreds of finished
/// agents (238 on 2026-10-05); stat-ing all of them every 500ms for every session is the cost
/// this avoids. Each tick stats the folder (a new file changes its stamp) and the non-done
/// files; every `fullRescanInterval` it stats everything, which is what notices a finished
/// agent resumed by `SendMessage`. The folder's own stamp is trusted for new files: APFS
/// keeps nanosecond mtimes, and the periodic rescan backstops a filesystem that does not.
///
/// **The disk work runs on `scanQueue`, never on the main queue.** The clock beats on main,
/// and main is also where the fleet server answers the phone. With 65 sessions open, these
/// scans filled 63% of the main thread (a 5s sample on 2026-10-14), and once macOS lowered
/// the app's priority — another app in front, or the display asleep — a `flightdeck ls`
/// waited 44s behind them and the phone took the silence for a dropped connection. A
/// `getattrlistbulk` was also caught blocked for a whole 5s sample with the display off. So a
/// tick reads its two inputs on main (they come from `SessionStore`), hands the scan to
/// `scanQueue`, and returns; the tree comes back to main to be published.
///
/// **One scan in flight per watcher.** A tick that finds its previous scan still running is
/// skipped rather than queued: under a slow disk, queued polls would pile up behind each
/// other and publish stale trees in a burst. A requested full rescan is the exception — it is
/// remembered and run when the scan in flight lands, because the fold asks for one when it
/// sees a launch and dropping it would leave the tree a launch behind.
@MainActor
final class SubagentWatcher {
    static let fullRescanInterval: TimeInterval = 10

    /// Shared by every watcher. Serial, so 65 sessions' scans take turns on one thread instead
    /// of each claiming one, and `.utility` because nothing here has a deadline.
    nonisolated static let scanQueue = DispatchQueue(label: "dev.flightdeck.subagent-scan",
                                                     qos: .utility)

    private let scanner: SubagentScanner
    private weak var clock: WatchClock?
    private let startedAt: () -> Date?
    private let keepDoneSince: () -> Date?
    private let onChange: (SubagentTree) -> Void
    var now: () -> Date = Date.init

    private(set) var tree = SubagentTree.empty
    private var inFlight = false
    private var rescanPending = false

    /// Stats performed by the last `poll` or `rescan`. A test seam for the steady-tick budget;
    /// read it only between scans.
    var statCount: Int { scanner.statCount }
    /// Agent files whose tail this watcher has read, over its whole life. A test seam: a tail
    /// read is the expensive half of a scan.
    var tailReadCount: Int { scanner.tailReadCount }
    /// Whether the last scan ran on the main thread. A test seam for the rule above.
    var lastScanRanOnMain: Bool? { scanner.lastScanRanOnMain }

    init(directory: URL, clock: WatchClock?, startedAt: @escaping () -> Date?,
         keepDoneSince: @escaping () -> Date?, onChange: @escaping (SubagentTree) -> Void) {
        self.scanner = SubagentScanner(directory: directory)
        self.clock = clock
        self.startedAt = startedAt
        self.keepDoneSince = keepDoneSince
        self.onChange = onChange
    }

    func start() { clock?.add(self) { [weak self] in self?.schedule(full: false) } }
    func stop() { clock?.remove(self) }

    /// A full rescan, run on `scanQueue`. What production calls; `rescan()` is the synchronous
    /// form tests drive.
    func requestRescan() { schedule(full: true) }

    /// One tick, synchronously. Cheap unless the folder or a live file changed, and free
    /// while the process start is unknown (see `SubagentScanner.rescan`). Production ticks go
    /// through `schedule(full:)` instead; this is the form tests drive.
    ///
    /// Through `scanQueue.sync`, so it waits out a scan already in flight instead of racing
    /// it on the scanner's dictionaries — `attach` schedules one, and a test that attaches
    /// and then drains is exactly that overlap (it segfaulted before this).
    func poll() {
        let since = startedAt(), at = now(), keep = keepDoneSince()
        apply(Self.scanQueue.sync { scanner.poll(since: since, now: at, keepDoneSince: keep) })
    }

    /// Everything, from scratch, synchronously. See `poll()` for who calls it and why `sync`.
    func rescan() {
        let since = startedAt(), at = now(), keep = keepDoneSince()
        apply(Self.scanQueue.sync { scanner.rescan(since: since, now: at, keepDoneSince: keep) })
    }

    private func schedule(full: Bool) {
        guard !inFlight else {
            if full { rescanPending = true }
            return
        }
        inFlight = true
        let since = startedAt(), at = now(), keep = keepDoneSince()
        let scanner = self.scanner
        Self.scanQueue.async {
            let next = full
                ? scanner.rescan(since: since, now: at, keepDoneSince: keep)
                : scanner.poll(since: since, now: at, keepDoneSince: keep)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.inFlight = false
                self.apply(next)
                if self.rescanPending {
                    self.rescanPending = false
                    self.schedule(full: true)
                }
            }
        }
    }

    private func apply(_ next: SubagentTree?) {
        guard let next, next != tree else { return }
        tree = next
        onChange(next)
    }
}

/// The scanning half of `SubagentWatcher`: the folder's state and the file reads.
///
/// `@unchecked Sendable` because its state is confined, not locked: production touches it only
/// on `SubagentWatcher.scanQueue`, one scan at a time (the watcher's `inFlight` guarantees
/// it), and tests touch it only from their own thread with no scan scheduled.
final class SubagentScanner: @unchecked Sendable {
    private let directory: URL
    private(set) var statCount = 0
    private(set) var tailReadCount = 0
    private(set) var lastScanRanOnMain: Bool?
    /// A nil value is a file whose meta was not yet readable: retried on every rescan, so an
    /// agent seen mid-creation is not left without a node for the life of the conversation.
    private var metas: [String: SubagentMeta?] = [:]
    private var scans: [String: (stamp: TranscriptStamp, state: SubagentNode.State)] = [:]
    private var folderStamp: TranscriptStamp?
    private var lastFullRescan = Date.distantPast

    init(directory: URL) { self.directory = directory }

    /// One tick. Returns the tree to publish, or nil when there is nothing new to build.
    func poll(since: Date?, now: Date, keepDoneSince: Date?) -> SubagentTree? {
        lastScanRanOnMain = Thread.isMainThread
        statCount = 0
        guard since != nil else { return nil }
        let folder = TranscriptStamp(of: directory)
        statCount += 1
        let folderChanged = folder != folderStamp
        let due = now.timeIntervalSince(lastFullRescan) >= SubagentWatcher.fullRescanInterval
        if folderChanged || due {
            return rescan(since: since, now: now, keepDoneSince: keepDoneSince)
        }
        var changed = false
        for (id, scan) in scans where scan.state != .done {
            let file = jsonl(id)
            statCount += 1
            guard let stamp = TranscriptStamp(of: file) else { continue }
            if stamp != scan.stamp {
                scans[id] = (stamp, readState(of: file))
                changed = true
            }
        }
        return changed ? build(keepDoneSince: keepDoneSince) : nil
    }

    /// Everything, from scratch: listing plus one stat per file, re-reading only what changed.
    ///
    /// **An unknown process start publishes nothing and reads nothing.** `since` is nil
    /// before the first registry row pins the tab, and always after claude exits (a dead pid
    /// has no start). Read as "no lower bound", that took every file the conversation ever
    /// wrote (238 on the live folder): half-finished agents from earlier runs showed as
    /// running, inflated the count, and each was tail-read. The last tree is kept instead
    /// (`.empty` if there never was one). `folderStamp` is left alone, so the first tick with
    /// a known start rescans.
    func rescan(since: Date?, now: Date, keepDoneSince: Date?) -> SubagentTree? {
        lastScanRanOnMain = Thread.isMainThread
        guard let since else {
            statCount = 0
            return nil
        }
        statCount = 1
        folderStamp = TranscriptStamp(of: directory)
        lastFullRescan = now
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? []
        var seen: Set<String> = []
        for file in files where file.pathExtension == "jsonl" {
            let name = file.deletingPathExtension().lastPathComponent
            guard name.hasPrefix("agent-") else { continue }
            let id = String(name.dropFirst("agent-".count))
            guard SubagentID.isValid(id) else { continue }
            statCount += 1
            guard let stamp = TranscriptStamp(of: file) else { continue }
            if stamp.modified < since { continue }
            seen.insert(id)
            if (metas[id] ?? nil) == nil {
                metas[id] = .some(SubagentFiles.meta(
                    at: directory.appendingPathComponent("agent-\(id).meta.json")))
            }
            if let previous = scans[id], previous.stamp == stamp { continue }
            scans[id] = (stamp, readState(of: file))
        }
        scans = scans.filter { seen.contains($0.key) }
        metas = metas.filter { seen.contains($0.key) }
        return build(keepDoneSince: keepDoneSince)
    }

    private func build(keepDoneSince: Date?) -> SubagentTree {
        let states = scans.mapValues { ($0.state, $0.stamp.modified) }
        return SubagentTree.build(metas: metas.compactMapValues { $0 }, states: states,
                                  keepDoneSince: keepDoneSince)
    }

    private func jsonl(_ id: String) -> URL { directory.appendingPathComponent("agent-\(id).jsonl") }

    private func readState(of file: URL) -> SubagentNode.State {
        tailReadCount += 1
        return Self.state(of: file)
    }

    private static func state(of file: URL) -> SubagentNode.State {
        let lines = TranscriptPager.page(url: file, anchor: .latest,
                                         limit: PromptService.tailRecords)?.lines ?? []
        return SubagentFiles.state(ofTail: lines)
    }
}
