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
///
/// **A conversation with nothing live rescans slowly.** The full rescan exists to notice a
/// finished agent resumed by `SendMessage`, and that only matters to someone watching a
/// conversation that is doing something. With every agent done (the usual state of a tab that
/// is idle, or asleep), the rescan backs off from `fullRescanInterval` to
/// `idleRescanInterval`: a measured 3.5% of a core went to re-listing 238-file folders that
/// had not changed. A folder change (a new agent) or `requestRescan()` (the fold saw a
/// launch) still rescans at once, and a resumed agent is noticed within the slow interval.
/// Skipping an asleep tab's ticks outright is not done here: the sleep set lives in
/// `SessionSleepController`, which the watcher has no reference to, and an asleep tab's agents
/// are mostly done, so the backoff already takes it to one listing a minute.
@MainActor
final class SubagentWatcher {
    static let fullRescanInterval: TimeInterval = 10
    /// The full rescan's interval while no agent is live. See the type comment.
    static let idleRescanInterval: TimeInterval = 60

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
    /// An agent absent from here has no readable meta yet: retried on every rescan, so an
    /// agent seen mid-creation is not left without a node for the life of the conversation.
    /// Not `[String: SubagentMeta?]`: the double optional made `build` and the pruning
    /// below spend their time in `type metadata accessor for Optional`.
    private var metas: [String: SubagentMeta] = [:]
    private var scans: [String: (stamp: TranscriptStamp, state: SubagentNode.State)] = [:]
    private var folderStamp: TranscriptStamp?
    private var lastFullRescan = Date.distantPast

    /// How soon after the last `rescan` `poll` runs another. Slow when no agent is live; see
    /// `SubagentWatcher`.
    private var rescanInterval: TimeInterval {
        scans.values.contains { $0.state != .done }
            ? SubagentWatcher.fullRescanInterval : SubagentWatcher.idleRescanInterval
    }

    init(directory: URL) { self.directory = directory }

    /// One tick. Returns the tree to publish, or nil when there is nothing new to build.
    func poll(since: Date?, now: Date, keepDoneSince: Date?) -> SubagentTree? {
        lastScanRanOnMain = Thread.isMainThread
        statCount = 0
        guard since != nil else { return nil }
        let folder = TranscriptStamp(of: directory)
        statCount += 1
        let folderChanged = folder != folderStamp
        let due = now.timeIntervalSince(lastFullRescan) >= rescanInterval
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

    /// Everything, from scratch: one directory listing, re-reading only what changed.
    ///
    /// **The listing is the stat.** `DirectoryStamps.list` takes every file's identity, size
    /// and nanosecond mtime from a single `getattrlistbulk`, the same call `contentsOfDirectory`
    /// makes, so a rescan stats nothing per file: 238 `stat`s were a third of its cost, and
    /// the files older than `since`, nearly all of them, are dropped on the listed mtime.
    /// The stamp is the same one `poll` takes with `stat`, inode included, so an append
    /// (size, mtime), a rewrite (mtime) and a replace (inode) are all still seen.
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
        var seen: Set<String> = []
        for (name, stamp) in DirectoryStamps.list(directory) {
            guard name.hasPrefix("agent-"), name.hasSuffix(".jsonl") else { continue }
            let id = String(name.dropFirst("agent-".count).dropLast(".jsonl".count))
            guard SubagentID.isValid(id), stamp.modified >= since else { continue }
            seen.insert(id)
            if metas[id] == nil {
                metas[id] = SubagentFiles.meta(
                    at: directory.appendingPathComponent("agent-\(id).meta.json"))
            }
            if let previous = scans[id], previous.stamp == stamp { continue }
            scans[id] = (stamp, readState(of: jsonl(id)))
        }
        // Pruning rebuilds a dictionary only when something is actually gone.
        if scans.count != seen.count || scans.keys.contains(where: { !seen.contains($0) }) {
            scans = scans.filter { seen.contains($0.key) }
        }
        if metas.keys.contains(where: { !seen.contains($0) }) {
            metas = metas.filter { seen.contains($0.key) }
        }
        return build(keepDoneSince: keepDoneSince)
    }

    private func build(keepDoneSince: Date?) -> SubagentTree {
        let states = scans.mapValues { ($0.state, $0.stamp.modified) }
        return SubagentTree.build(metas: metas, states: states, keepDoneSince: keepDoneSince)
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

/// A folder's regular files with their `TranscriptStamp`s, from one `getattrlistbulk` pass.
///
/// Why not `contentsOfDirectory(includingPropertiesForKeys:)`: its values are a `Date` (a
/// `Double`, so no nanoseconds) and no inode, and reading them back costs a dictionary per
/// file. Measured over 240 files that was no cheaper than a `stat` each. This asks the
/// kernel for exactly the five numbers a stamp holds and returns the stamp itself.
enum DirectoryStamps {
    /// Empty when the folder cannot be opened or listed, like the `try?` it replaces.
    static func list(_ directory: URL) -> [(name: String, stamp: TranscriptStamp)] {
        let fd = open(directory.path, O_RDONLY | O_DIRECTORY)
        guard fd >= 0 else { return [] }
        defer { close(fd) }
        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS) | attrgroup_t(ATTR_CMN_NAME)
            | attrgroup_t(ATTR_CMN_DEVID) | attrgroup_t(ATTR_CMN_OBJTYPE)
            | attrgroup_t(ATTR_CMN_MODTIME) | attrgroup_t(ATTR_CMN_FILEID)
        request.fileattr = attrgroup_t(ATTR_FILE_DATALENGTH)
        let wanted = request.commonattr & ~attrgroup_t(ATTR_CMN_RETURNED_ATTRS)

        var buffer = [UInt8](repeating: 0, count: 128 * 1024)
        var found: [(name: String, stamp: TranscriptStamp)] = []
        buffer.withUnsafeMutableBytes { raw in
            while true {
                let count = getattrlistbulk(fd, &request, raw.baseAddress, raw.count, 0)
                guard count > 0 else { return }
                var entry = raw.baseAddress!
                for _ in 0..<count {
                    let length = Int(entry.loadUnaligned(as: UInt32.self))
                    defer { entry += length }
                    // Layout, in attribute-bit order: length, returned set, name reference,
                    // device, object type, mtime, file id, data length. All packed to 4.
                    var field = entry + 4
                    let returned = field.loadUnaligned(as: attribute_set_t.self)
                    field += MemoryLayout<attribute_set_t>.size
                    guard returned.commonattr & wanted == wanted,
                          returned.fileattr & attrgroup_t(ATTR_FILE_DATALENGTH) != 0 else { continue }
                    let nameAt = field
                    let reference = nameAt.loadUnaligned(as: attrreference_t.self)
                    field += MemoryLayout<attrreference_t>.size
                    let device = field.loadUnaligned(as: Int32.self); field += 4
                    let type = field.loadUnaligned(as: UInt32.self); field += 4
                    let mtime = field.loadUnaligned(as: timespec.self)
                    field += MemoryLayout<timespec>.size
                    let inode = field.loadUnaligned(as: UInt64.self); field += 8
                    let size = field.loadUnaligned(as: Int64.self)
                    guard type == VREG.rawValue else { continue }
                    let name = String(cString: (nameAt + Int(reference.attr_dataoffset))
                        .assumingMemoryBound(to: CChar.self))
                    found.append((name, TranscriptStamp(
                        device: device, inode: inode, size: size,
                        mtimeSeconds: mtime.tv_sec, mtimeNanoseconds: mtime.tv_nsec)))
                }
            }
        }
        return found
    }
}
