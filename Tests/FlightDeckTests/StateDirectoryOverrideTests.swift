import XCTest
@testable import FlightDeck

/// `-FlightDeckStateDir <path>` exists so a debug instance can be pointed at a *copy* of
/// `sessions.json` instead of the real one.
///
/// The motivating incident: an attempt to isolate a debug run with `HOME=<scratch>` did not
/// isolate anything. `FileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)`
/// resolves the real home through `getpwuid`, ignoring the environment, so the instance
/// restored the developer's live sessions and began spawning duplicate `claude --resume`
/// processes — the exact collision `scripts/swap-release.sh` documents at length. There was no
/// supported way to run against cloned state; this is it.
@MainActor
final class StateDirectoryOverrideTests: XCTestCase {
    /// A defaults domain of our own, so these cases never read or write the app's real one.
    private func makeDefaults(_ name: String = #function) -> UserDefaults {
        let suite = "FlightDeckStateDirTests.\(name)"
        UserDefaults().removePersistentDomain(forName: suite)
        return UserDefaults(suiteName: suite)!
    }

    func testAbsentFlagMeansNoOverride() {
        XCTAssertNil(FlightDeckApp.stateDirectory(makeDefaults()))
    }

    /// An empty string is what `-FlightDeckStateDir ""` produces. Treating it as "no override"
    /// rather than as the current directory keeps a malformed launch on the real path instead
    /// of silently writing sessions.json somewhere arbitrary.
    func testEmptyFlagMeansNoOverride() {
        let defaults = makeDefaults()
        defaults.set("", forKey: "FlightDeckStateDir")
        XCTAssertNil(FlightDeckApp.stateDirectory(defaults))
    }

    func testFlagResolvesToADirectoryURL() {
        let defaults = makeDefaults()
        defaults.set("/tmp/flight-deck-state-test", forKey: "FlightDeckStateDir")

        let url = FlightDeckApp.stateDirectory(defaults)

        XCTAssertEqual(url?.path, "/tmp/flight-deck-state-test")
        XCTAssertTrue(url?.hasDirectoryPath == true)
    }

    /// A tilde is how anyone will actually type this on a command line.
    func testFlagExpandsATilde() {
        let defaults = makeDefaults()
        defaults.set("~/fd-state", forKey: "FlightDeckStateDir")

        let url = FlightDeckApp.stateDirectory(defaults)

        XCTAssertEqual(url?.path, NSHomeDirectory() + "/fd-state")
        XCTAssertFalse(url?.path.contains("~") == true)
    }

    /// The override has to read and write the directory it was given, or it is not isolation.
    func testOverriddenStoreReadsAndWritesTheGivenDirectory() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("fd-state-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let persistence = FileSessionPersistence(directory: dir, legacyDefaults: nil)
        var snapshot = SessionSnapshot(sessions: [], sessionCounter: 7)
        snapshot.terminalSize = .init(width: 640, height: 480)
        persistence.save(snapshot)

        let onDisk = dir.appendingPathComponent("sessions.json")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: onDisk.path),
            "the override must write into the directory it was given")
        XCTAssertEqual(FileSessionPersistence(directory: dir, legacyDefaults: nil).load(), snapshot)
    }

    /// The safety property that makes this usable against a *clone* of live state.
    ///
    /// `migrateFromDefaults` removes the legacy defaults key once it has written the file. If an
    /// overridden store were allowed to migrate, pointing a debug instance at a scratch
    /// directory would consume the real user's legacy blob as a side effect — isolation that
    /// mutates the thing it is isolating from.
    func testAnOverriddenStoreNeverTouchesTheLegacyDefaultsKey() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("fd-state-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let legacy = makeDefaults()
        let blob = try JSONEncoder().encode(
            SessionSnapshot(sessions: [.init(id: UUID(), title: "live", workingDirectory: "/w")],
                            sessionCounter: 1))
        legacy.set(blob, forKey: FileSessionPersistence.legacyKey)

        // No sessions.json in `dir`, which is exactly when migration would otherwise fire.
        XCTAssertNil(FileSessionPersistence(directory: dir, legacyDefaults: nil).load())

        XCTAssertNotNil(
            legacy.data(forKey: FileSessionPersistence.legacyKey),
            "an overridden store must leave the real legacy blob alone")
    }
}
