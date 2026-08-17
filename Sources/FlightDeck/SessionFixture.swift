import Foundation
import OSLog

/// A posed deck, loaded from a directory named on the command line.
///
/// This exists for one caller: the screenshot UI test, which needs a sidebar holding several
/// projects and a session in every status at once. There is no production route to that state
/// — statuses come from live `claude` processes — so the test supplies the inputs the real
/// code paths read, and the app resolves them exactly as it would on a normal launch.
///
/// The directory holds three things:
///
///  - `sessions.json` — a `SessionSnapshot`, restored through the ordinary `restore()` path.
///  - `status/`       — Claude status files, read by `SessionStatusWatcher` in place of
///                      `~/.claude/sessions`, so the sidebar glyphs are *derived* by
///                      `applyRegistry` rather than drawn by the test.
///  - `projects/`     — transcripts, read by `TranscriptWatcher` in place of
///                      `~/.claude/projects`. Supplies the sub-agent fan-out counts, and
///                      keeps a fixture run from reading the real transcript tree at all.
///  - `shell`         — an executable the seeded sessions run instead of the login shell.
///
/// That last one is not a nicety. A session normally launches the user's login shell, whose
/// profile is what starts `claude` (Flight Deck → login → fish → claude). A fixture run that
/// used the real shell would spawn a live `claude` per seeded session, each registering in the
/// pid-keyed registry under `~/.claude/sessions` — i.e. the fixture would corrupt exactly the
/// live state it is supposed to leave alone.
///
/// Nothing here writes. See `FixtureSessionPersistence.save`.
struct SessionFixture {
    let root: URL

    var snapshotURL: URL { root.appendingPathComponent("sessions.json") }
    var statusRoot: URL { root.appendingPathComponent("status") }
    var projectsRoot: URL { root.appendingPathComponent("projects") }
    var shellURL: URL { root.appendingPathComponent("shell") }

    @MainActor
    func persistence() -> FixtureSessionPersistence {
        FixtureSessionPersistence(fileURL: snapshotURL)
    }
}

/// Reads a `SessionSnapshot` from a file and discards every write.
///
/// The discard is the contract. `SessionStore` persists on essentially every mutation, and
/// restoring a fixture is itself a mutation — so a fixture run backed by anything that wrote
/// would replace the developer's real `sessions.json` with the posed deck within milliseconds
/// of launch. Covered by `SessionFixtureTests`.
@MainActor
final class FixtureSessionPersistence: SessionPersisting {
    private static let logger = Logger(
        subsystem: "dev.flightdeck.FlightDeck", category: "fixture"
    )

    private let fileURL: URL

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    func load() -> SessionSnapshot? {
        guard let data = try? Data(contentsOf: fileURL) else {
            Self.logger.error("no fixture snapshot at \(self.fileURL.path, privacy: .public)")
            return nil
        }
        guard let snapshot = try? JSONDecoder().decode(SessionSnapshot.self, from: data) else {
            Self.logger.error("fixture snapshot did not decode; seeding normally instead")
            return nil
        }
        return snapshot
    }

    /// Deliberately empty — see the type's doc comment. Do not "fix" this.
    func save(_ snapshot: SessionSnapshot) {}
}
