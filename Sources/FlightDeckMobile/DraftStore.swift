import Foundation

/// What is typed in each conversation's composer, kept on disk as it is typed.
///
/// **Written on every change, not on quit, because the ways this app ends give no warning.**
/// A crash, a force quit from the app switcher, a jetsam kill and `deploy-phone.sh`'s
/// `--terminate-existing` all end the process without a lifecycle callback, and a draft held
/// only in `SessionTimelineModel.draft` went with it. The maintainer lost messages that way on every
/// phone deploy. Each change is handed to a serial queue and written there, the newest text
/// winning, so typing costs the main thread nothing.
///
/// **Application Support, not Caches.** Everything `PhoneCache` holds can be fetched again
/// from the Mac; a draft exists nowhere else, so it must not live where iOS purges under
/// storage pressure. It is excluded from backup, since it is prompt text on its way to a Mac.
///
/// Holds what a person typed, so it goes with the pairing: `purgeAll()` on unpair and on
/// adopting a new pairing, the same as `PhoneCache` and `TimelineSpillStore`.
final class DraftStore: @unchecked Sendable {
    private let directory: URL
    private let queue = DispatchQueue(label: "flightdeck.drafts")

    init(directory: URL? = nil) {
        self.directory = directory ?? Self.defaultDirectory()
    }

    static func defaultDirectory() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return support.appendingPathComponent("FlightDeckDrafts", isDirectory: true)
    }

    private func url(_ session: UUID) -> URL {
        directory.appendingPathComponent("\(session.uuidString).txt")
    }

    /// The saved draft for `session`, or nil when there is none. Synchronous, and ordered after
    /// every save already handed to this store, so a model rebuilt mid-typing reads the newest.
    func draft(for session: UUID) -> String? {
        queue.sync {
            guard let data = try? Data(contentsOf: url(session)), !data.isEmpty else { return nil }
            return String(decoding: data, as: UTF8.self)
        }
    }

    /// Keep `text` as `session`'s draft; an empty one removes it, which is what a send does.
    func save(_ text: String, for session: UUID) {
        let target = url(session)
        let directory = directory
        queue.async {
            if text.isEmpty {
                try? FileManager.default.removeItem(at: target)
                return
            }
            if !FileManager.default.fileExists(atPath: directory.path) {
                try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                var folder = directory
                var values = URLResourceValues()
                values.isExcludedFromBackup = true
                try? folder.setResourceValues(values)
            }
            try? Data(text.utf8).write(to: target, options: .atomic)
        }
    }

    /// Drop every draft except `sessions`': a tab the Mac has closed has nowhere to send one.
    func prune(keeping sessions: Set<UUID>) {
        let directory = directory
        queue.async {
            let files = (try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil
            )) ?? []
            for file in files {
                if let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent),
                   sessions.contains(id) { continue }
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    /// Every draft. Synchronous, so a revocation is complete when it returns.
    func purgeAll() {
        let directory = directory
        queue.sync { _ = try? FileManager.default.removeItem(at: directory) }
    }

    /// Wait for every save handed over so far to reach disk. For tests.
    func flush() {
        queue.sync {}
    }
}
