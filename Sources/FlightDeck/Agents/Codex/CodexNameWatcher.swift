import Foundation

/// Tails codex's `session_index.jsonl` and reports thread renames.
///
/// One instance for the whole app, not one per tab, for the same reason `SessionStatusWatcher`
/// is shared: a single file carries every thread, so a per-tab watcher would read the same
/// bytes N times.
///
/// This file is the ONLY place a codex rename is observable. The rollout carries none — not
/// from `thread/name/set`, not from a `/rename` typed into the TUI — and the app-server tells
/// only the connection that made the change. Verified against codex-cli 0.148.0: three
/// renames from two different writers produced three lines here and nothing anywhere else.
@MainActor
final class CodexNameWatcher {
    /// Codex's index, honouring `CODEX_HOME` exactly as codex does. Getting this wrong fails
    /// silently — a watcher on the wrong path simply never reports anything.
    nonisolated static var defaultIndexURL: URL {
        indexURL(codexHome: ProcessInfo.processInfo.environment["CODEX_HOME"],
                 home: FileManager.default.homeDirectoryForCurrentUser)
    }

    /// Pure decision behind `defaultIndexURL`, split out so both branches are testable
    /// without depending on whether `CODEX_HOME` happens to be set in the test process.
    nonisolated static func indexURL(codexHome: String?, home: URL) -> URL {
        let base = codexHome
            .map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) }
            ?? home.appendingPathComponent(".codex", isDirectory: true)
        return base.appendingPathComponent("session_index.jsonl")
    }

    let url: URL

    private var listeners: [UUID: (String) -> Void] = [:]
    private var offset: UInt64 = 0
    private var hasChosenStart = false
    private weak var clock: WatchClock?
    private var isPolling = false

    init(url: URL = CodexNameWatcher.defaultIndexURL, clock: WatchClock? = nil) {
        self.url = url
        self.clock = clock
    }

    func register(_ id: UUID, onTitle: @escaping (String) -> Void) {
        listeners[id] = onTitle
    }

    func unregister(_ id: UUID) {
        listeners[id] = nil
    }

    /// Lets the owner drop this watcher with the last codex tab rather than leave it ticking
    /// over a file nothing is listening to.
    var isEmpty: Bool { listeners.isEmpty }

    func start() {
        clock?.add(self) { [weak self] in self?.poll() }
    }

    func stop() {
        clock?.remove(self)
    }

    private func poll() {
        guard !isPolling else { return }
        isPolling = true

        let url = self.url
        let offset = self.offset
        let hasChosenStart = self.hasChosenStart

        Task { [weak self] in
            let read = await Task.detached(priority: .utility) {
                TailReader.read(url: url, offset: offset, hasChosenStart: hasChosenStart,
                                truncation: .resumeAtEnd)
            }.value

            guard let self else { return }
            self.apply(read)
            self.isPolling = false
        }
    }

    /// Synchronous pass, so tests need no expectations.
    func drain() {
        apply(TailReader.read(url: url, offset: offset, hasChosenStart: hasChosenStart,
                              truncation: .resumeAtEnd))
    }

    private func apply(_ read: TailRead) {
        hasChosenStart = read.hasChosenStart
        offset = read.offset

        for line in read.lines {
            guard let raw = try? JSONSerialization.jsonObject(with: Data(line.utf8)),
                  let record = raw as? [String: Any],
                  let id = (record["id"] as? String).flatMap(UUID.init(uuidString:)),
                  let name = record["thread_name"] as? String,
                  let listener = listeners[id]
            else { continue }
            listener(name)
        }
    }
}
