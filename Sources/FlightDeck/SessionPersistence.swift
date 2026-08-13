// Sources/FlightDeck/SessionPersistence.swift
import Foundation
import OSLog

/// What survives a relaunch. Repos are derived from `workingDirectory`, so only
/// sessions are stored and the grouping rebuilds on restore.
struct SessionSnapshot: Codable, Equatable {
    struct Entry: Codable, Equatable {
        let id: UUID
        var title: String
        var workingDirectory: String
        /// Absent in v1 snapshots and in tabs that were never resumed; absent means
        /// "same as `id`". Optional is load-bearing: synthesized `Codable` decodes an
        /// optional with `decodeIfPresent`, so every existing snapshot still decodes and
        /// the defaults key stays `sessions.snapshot.v1`. A non-optional field would throw
        /// and wipe every tab on the first launch after this change.
        var pinnedConversationID: UUID?

        init(
            id: UUID,
            title: String,
            workingDirectory: String,
            pinnedConversationID: UUID? = nil
        ) {
            self.id = id
            self.title = title
            self.workingDirectory = workingDirectory
            self.pinnedConversationID = pinnedConversationID
        }
    }

    var sessions: [Entry] = []
    var selectedSessionID: UUID?
    /// Persisted so a new session cannot reuse a restored session's number.
    var sessionCounter: Int = 0
}

@MainActor
protocol SessionPersisting: AnyObject {
    func load() -> SessionSnapshot?
    func save(_ snapshot: SessionSnapshot)
}

/// Stores the snapshot in the app's standard defaults domain (`dev.flightdeck.FlightDeck`).
///
/// Superseded by `FileSessionPersistence` — see the rationale on that type. Kept because it
/// is still the simplest `SessionPersisting` to construct in a test, and because
/// `FileSessionPersistence` migrates the key this type owns.
@MainActor
final class UserDefaultsSessionPersistence: SessionPersisting {
    private let defaults: UserDefaults
    private let key = "sessions.snapshot.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> SessionSnapshot? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(SessionSnapshot.self, from: data)
    }

    func save(_ snapshot: SessionSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: key)
    }
}

/// Stores the snapshot as JSON in Application Support, migrating once from the
/// `UserDefaults` key `UserDefaultsSessionPersistence` used to own.
///
/// **Why not `UserDefaults`.** Three reasons, in order of how much they bit us:
///
/// 1. *Blast radius.* `defaults delete dev.flightdeck.FlightDeck` is a routine debugging
///    gesture — `scripts/smoke.sh` did exactly that on every run and destroyed every real
///    session and project along with the preferences it meant to reset. Preferences are
///    cheap to lose; the session graph is not. Different durability needs, different stores.
/// 2. *Write durability.* `cfprefsd` coalesces writes asynchronously, so a `SIGKILL` (or a
///    force-quit mid-development) can drop the most recent one. `Data.write(options: .atomic)`
///    commits at a known instant via a rename.
/// 3. *Growth and inspectability.* This blob grows with sessions × projects × pinned
///    conversations. As a file it is greppable, diffable, and backup-friendly.
///
/// Preferences deliberately stay in `UserDefaults` (`UserDefaultsPreferencesPersistence`) —
/// that is what the defaults system is for. This split matches the platform convention:
/// iTerm2 keeps settings in a plist and window arrangements in Application Support.
@MainActor
final class FileSessionPersistence: SessionPersisting {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "dev.flightdeck.FlightDeck",
        category: String(describing: FileSessionPersistence.self)
    )

    /// The `UserDefaults` key this store superseded. Read once, on first load, then cleared.
    static let legacyKey = "sessions.snapshot.v1"

    private let fileURL: URL
    private let legacyDefaults: UserDefaults?

    /// - Parameters:
    ///   - directory: where `sessions.json` lives. Defaults to
    ///     `~/Library/Application Support/Flight Deck`. Injectable so tests get a temp dir
    ///     instead of touching the real one.
    ///   - legacyDefaults: the domain to migrate from, or `nil` to skip migration.
    init(
        directory: URL? = nil,
        legacyDefaults: UserDefaults? = .standard
    ) {
        let dir = directory ?? Self.defaultDirectory()
        self.fileURL = dir.appendingPathComponent("sessions.json", isDirectory: false)
        self.legacyDefaults = legacyDefaults
    }

    static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        // "Flight Deck" (two words) matches the product name on disk, as in `Flight Deck.app`.
        return base.appendingPathComponent("Flight Deck", isDirectory: true)
    }

    func load() -> SessionSnapshot? {
        if let data = try? Data(contentsOf: fileURL),
           let snapshot = try? JSONDecoder().decode(SessionSnapshot.self, from: data) {
            return snapshot
        }
        return migrateFromDefaults()
    }

    func save(_ snapshot: SessionSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        write(data)
    }

    /// One-shot move of an existing defaults blob into the file. Returns what it migrated so
    /// the very first `load()` after upgrading still restores the user's tabs rather than
    /// seeding a fresh slate.
    ///
    /// The defaults key is removed only after the file write is confirmed on disk: if the
    /// write fails we keep the old copy and try again next launch, so a failed migration
    /// degrades to "still on the old store" instead of "state gone".
    private func migrateFromDefaults() -> SessionSnapshot? {
        guard let legacyDefaults,
              let data = legacyDefaults.data(forKey: Self.legacyKey),
              let snapshot = try? JSONDecoder().decode(SessionSnapshot.self, from: data)
        else { return nil }

        guard write(data) else {
            Self.logger.warning("session migration deferred: file write failed")
            return snapshot
        }
        legacyDefaults.removeObject(forKey: Self.legacyKey)
        Self.logger.info("migrated \(snapshot.sessions.count) session(s) to \(self.fileURL.path)")
        return snapshot
    }

    @discardableResult
    private func write(_ data: Data) -> Bool {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: fileURL, options: .atomic)
            return true
        } catch {
            Self.logger.warning("session save failed: \(error.localizedDescription)")
            return false
        }
    }
}
