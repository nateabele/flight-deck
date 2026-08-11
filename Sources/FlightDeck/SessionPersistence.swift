// Sources/FlightDeck/SessionPersistence.swift
import Foundation

/// What survives a relaunch. Repos are derived from `workingDirectory`, so only
/// sessions are stored and the grouping rebuilds on restore.
struct SessionSnapshot: Codable, Equatable {
    struct Entry: Codable, Equatable {
        let id: UUID
        var title: String
        let workingDirectory: String
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

/// Stores the snapshot in the app's standard defaults domain
/// (`dev.flightdeck.FlightDeck`), which `scripts/smoke.sh` already wipes so the
/// UITest gate stays hermetic.
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
