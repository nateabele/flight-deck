import Foundation

/// The hand-off log, read for the Observe drawer. Pure functions here; the cache below owns the I/O.
enum HandoffHistory {
    /// One line per JSON object. A torn last line (the writer appends without a lock) or a line a
    /// newer build wrote with an outcome this build does not know is skipped, never fatal: the
    /// drawer showing the other entries beats showing none.
    static func parse(_ data: Data) -> [HandoffLogEntry] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return data.split(separator: 0x0A).compactMap { try? decoder.decode(HandoffLogEntry.self, from: Data($0)) }
    }

    /// Entries naming `session` as the old or the new agent, newest first, as drawer lines.
    static func lines(for session: UUID, entries: [HandoffLogEntry],
                      timeZone: TimeZone = .current, locale: Locale = .current) -> [String] {
        entries.filter { $0.oldSession == session || $0.newSession == session }
            .sorted { $0.at > $1.at }
            .map { line($0, timeZone: timeZone, locale: locale) }
    }

    static func line(_ e: HandoffLogEntry, timeZone: TimeZone, locale: Locale) -> String {
        let when = e.at.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, locale: locale, timeZone: timeZone))
        let who: String
        switch e.outcome {
        case .handedOff:
            who = "\(e.oldAgent) → \(e.newAgent ?? "a new agent") · \(e.fromAccount) → \(e.toAccount ?? "?")"
        case .spawnFailed: who = "\(e.oldAgent) could not hand off from \(e.fromAccount)"
        case .waitingForCapacity: who = "\(e.oldAgent) waits for capacity off \(e.fromAccount)"
        case .declined: who = "\(e.oldAgent) hand-off declined"
        case .interrupted: who = "\(e.oldAgent) hand-off interrupted"
        case .stopFailed: who = "\(e.oldAgent) could not be stopped after hand-off"
        case .unrecorded: who = "\(e.oldAgent) hand-off not recorded"
        }
        return "\(when) · task \(e.task) · \(who)"
    }
}

/// Keeps the parsed log in memory so a drawer render never touches the disk. `refresh()` reads on a
/// background queue and only when the file's modification date moved; without that, every render of
/// a focused swarm tab would re-read and re-parse an append-only file that only grows.
@MainActor
final class HandoffHistoryCache: ObservableObject {
    static let shared = HandoffHistoryCache()

    @Published private(set) var all: [HandoffLogEntry] = []
    /// How many times the file was actually read, for the test that pins "unchanged is not re-read".
    private(set) var reads = 0
    private let logURL: URL
    private var lastStamp: Date?
    private var refreshing = false

    init(logURL: URL = StoreHandoffHost.defaultLogURL) { self.logURL = logURL }

    func entries(for session: UUID) -> [HandoffLogEntry] {
        all.filter { $0.oldSession == session || $0.newSession == session }
    }

    func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        let url = logURL
        let known = lastStamp
        let result: (Date?, [HandoffLogEntry]?) = await Task.detached(priority: .utility) {
            let stamp = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
            if let stamp, stamp == known { return (stamp, nil) }
            guard let data = try? Data(contentsOf: url) else { return (stamp, stamp == nil ? [] : nil) }
            return (stamp, HandoffHistory.parse(data))
        }.value
        lastStamp = result.0
        if let parsed = result.1 {
            reads += 1
            if parsed != all { all = parsed }
        }
    }
}
