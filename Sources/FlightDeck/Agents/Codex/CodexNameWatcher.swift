import Foundation

/// Tails codex's `session_index.jsonl` and reports thread renames.
///
/// One instance per account, not one per tab, for the same reason `SessionStatusWatcher` is:
/// a single file carries every thread that account owns, so a per-tab watcher would read the
/// same bytes N times. It stops at the account, though — a second login is a second
/// `CODEX_HOME` and therefore a second index file, which no shared watcher could ever tail.
///
/// This file is the ONLY place a codex rename is observable. The rollout carries none — not
/// from `thread/name/set`, not from a `/rename` typed into the TUI — and the app-server tells
/// only the connection that made the change. Verified against codex-cli 0.148.0: three
/// renames from two different writers produced three lines here and nothing anywhere else.
@MainActor
final class CodexNameWatcher {
    /// The index inside one `CODEX_HOME`. Getting this wrong fails silently — a watcher on the
    /// wrong path simply never reports anything.
    ///
    /// Takes the home rather than reading `CODEX_HOME` itself. It used to read Flight Deck's
    /// OWN process environment, which resolved one path, once, for every tab — correct only
    /// while the app had a single login, and wrong the moment a tab is spawned with a
    /// different `CODEX_HOME` than the one Flight Deck was launched with. The account's home
    /// is the only thing that knows where a given tab's threads are indexed.
    nonisolated static func indexURL(forHome home: URL) -> URL {
        home.appendingPathComponent("session_index.jsonl")
    }

    /// The built-in login's index. Kept for the callers that have no account in hand — the
    /// `init` default below, and tests — never as "the" index.
    nonisolated static var defaultIndexURL: URL {
        indexURL(forHome: AgentID.codex.builtInHome)
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
