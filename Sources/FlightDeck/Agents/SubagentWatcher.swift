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
@MainActor
final class SubagentWatcher {
    static let fullRescanInterval: TimeInterval = 10

    private let directory: URL
    private weak var clock: WatchClock?
    private let startedAt: () -> Date?
    private let keepDoneSince: () -> Date?
    private let onChange: (SubagentTree) -> Void
    var now: () -> Date = Date.init

    private(set) var tree = SubagentTree.empty
    /// Stats performed by the last `poll` or `rescan`. A test seam for the steady-tick budget.
    private(set) var statCount = 0
    /// A nil value is a file whose meta was not yet readable: retried on every rescan, so an
    /// agent seen mid-creation is not left without a node for the life of the conversation.
    private var metas: [String: SubagentMeta?] = [:]
    private var scans: [String: (stamp: TranscriptStamp, state: SubagentNode.State)] = [:]
    private var folderStamp: TranscriptStamp?
    private var lastFullRescan = Date.distantPast

    init(directory: URL, clock: WatchClock?, startedAt: @escaping () -> Date?,
         keepDoneSince: @escaping () -> Date?, onChange: @escaping (SubagentTree) -> Void) {
        self.directory = directory
        self.clock = clock
        self.startedAt = startedAt
        self.keepDoneSince = keepDoneSince
        self.onChange = onChange
    }

    func start() { clock?.add(self) { [weak self] in self?.poll() } }
    func stop() { clock?.remove(self) }

    /// One tick. Cheap unless the folder or a live file changed.
    func poll() {
        statCount = 0
        let folder = TranscriptStamp(of: directory)
        statCount += 1
        let folderChanged = folder != folderStamp
        let due = now().timeIntervalSince(lastFullRescan) >= Self.fullRescanInterval
        if folderChanged || due {
            rescan()
            return
        }
        var changed = false
        for (id, scan) in scans where scan.state != .done {
            let file = jsonl(id)
            statCount += 1
            guard let stamp = TranscriptStamp(of: file) else { continue }
            if stamp != scan.stamp {
                scans[id] = (stamp, Self.state(of: file))
                changed = true
            }
        }
        if changed { publish() }
    }

    /// Everything, from scratch: listing plus one stat per file, re-reading only what changed.
    func rescan() {
        statCount = 1
        folderStamp = TranscriptStamp(of: directory)
        lastFullRescan = now()
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? []
        let since = startedAt()
        var seen: Set<String> = []
        for file in files where file.pathExtension == "jsonl" {
            let name = file.deletingPathExtension().lastPathComponent
            guard name.hasPrefix("agent-") else { continue }
            let id = String(name.dropFirst("agent-".count))
            guard SubagentID.isValid(id) else { continue }
            statCount += 1
            guard let stamp = TranscriptStamp(of: file) else { continue }
            if let since, stamp.modified < since { continue }
            seen.insert(id)
            if (metas[id] ?? nil) == nil {
                metas[id] = .some(SubagentFiles.meta(
                    at: directory.appendingPathComponent("agent-\(id).meta.json")))
            }
            if let previous = scans[id], previous.stamp == stamp { continue }
            scans[id] = (stamp, Self.state(of: file))
        }
        scans = scans.filter { seen.contains($0.key) }
        metas = metas.filter { seen.contains($0.key) }
        publish()
    }

    private func publish() {
        let states = scans.mapValues { ($0.state, $0.stamp.modified) }
        let next = SubagentTree.build(metas: metas.compactMapValues { $0 }, states: states,
                                      keepDoneSince: keepDoneSince())
        guard next != tree else { return }
        tree = next
        onChange(next)
    }

    private func jsonl(_ id: String) -> URL { directory.appendingPathComponent("agent-\(id).jsonl") }

    private static func state(of file: URL) -> SubagentNode.State {
        let lines = TranscriptPager.page(url: file, anchor: .latest,
                                         limit: PromptService.tailRecords)?.lines ?? []
        return SubagentFiles.state(ofTail: lines)
    }
}
