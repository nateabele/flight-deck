import Foundation

/// Polls Claude Code's per-process status registry and reports every live session's
/// status, keyed by the session UUID Flight Deck assigned with `--session-id`.
///
/// One instance serves the whole app: the registry is a single flat directory, so a
/// per-session watcher would re-scan the same files N times.
///
/// Polling rather than a vnode watch is forced by how `claude` writes the file — a
/// non-atomic in-place `writeFile`, with no create/rename, so a directory watch would
/// never fire on a status change. That same in-place write means a read can land
/// mid-write; see `drain()`.
@MainActor
final class SessionStatusWatcher {
    nonisolated static var defaultRoot: URL {
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent(".claude/sessions", isDirectory: true)
    }

    /// `EPERM` means the process exists but belongs to another user — still alive.
    nonisolated static let processIsAlive: (pid_t) -> Bool = { pid in
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    private let root: URL
    private let isAlive: (pid_t) -> Bool
    private let onChange: ([pid_t: ClaudeStatusFile.Entry]) -> Void

    /// Last successfully decoded entry per filename. Survives a torn read so a
    /// half-written file does not read as "session gone".
    private var cache: [String: ClaudeStatusFile.Entry] = [:]
    private var mtimes: [String: Date] = [:]
    private var timer: DispatchSourceTimer?

    init(
        root: URL = SessionStatusWatcher.defaultRoot,
        isAlive: @escaping (pid_t) -> Bool = SessionStatusWatcher.processIsAlive,
        onChange: @escaping ([pid_t: ClaudeStatusFile.Entry]) -> Void
    ) {
        self.root = root
        self.isAlive = isAlive
        self.onChange = onChange
    }

    deinit { timer?.cancel() }

    /// 500 ms matches `TranscriptWatcher`; the registry is a handful of small files.
    func start() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now(), repeating: .milliseconds(500))
        t.setEventHandler { [weak self] in self?.drain() }
        timer = t
        t.resume()
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    /// Rescans the registry and reports the current map. Synchronous so tests need no
    /// expectations. A missing root is normal (no `claude` has ever run) and reports
    /// an empty map rather than failing.
    func drain() {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        var live: [String: ClaudeStatusFile.Entry] = [:]

        for name in names {
            guard let pid = ClaudeStatusFile.pid(fromFileName: name), isAlive(pid) else {
                continue
            }
            let url = root.appendingPathComponent(name)
            let mtime = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date

            // Unchanged since the last look: reuse the decoded entry.
            if let mtime, mtimes[name] == mtime, let cached = cache[name] {
                live[name] = cached
                continue
            }

            if let data = try? Data(contentsOf: url),
               let entry = ClaudeStatusFile.decode(data, expectedPID: pid) {
                cache[name] = entry
                mtimes[name] = mtime
                live[name] = entry
            } else if let cached = cache[name] {
                // Torn or momentarily invalid: keep the last good value and re-read
                // next tick. Deliberately does not update `mtimes`.
                live[name] = cached
            }
        }

        // Drop cache for files that vanished, so a closed session stops reporting.
        let present = Set(live.keys)
        cache = cache.filter { present.contains($0.key) }
        mtimes = mtimes.filter { present.contains($0.key) }

        // Keyed by pid, not by session: a tab follows its *process*, and two live
        // processes can legitimately hold one conversation once resumes are in play.
        // Collapsing by session id here would hide one of them and would throw away the
        // mapping `ConversationPin` anchors on.
        var byPID: [pid_t: ClaudeStatusFile.Entry] = [:]
        for entry in live.values { byPID[entry.pid] = entry }
        onChange(byPID)
    }
}
