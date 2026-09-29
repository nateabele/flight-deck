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

    // MARK: - Debug builds never share the live state directory

    /// The 2026-09-29 incident: a Debug bundle launched from a worktree's DerivedData restored
    /// the live `sessions.json` and started a second `claude --resume` for all 62 sessions. The
    /// duplicates outlived the app, and because each wrote its own `~/.claude/sessions/<pid>.json`
    /// with a newer `startedAt`, they won the registry tie-break over the real agents — every
    /// question raised afterwards read as `idle` and never reached the phone. Separate daemon
    /// roots (`SessionDaemon.defaultDirectory(debug:)`) did not help, because the thing that
    /// resumes agents is `restore()`, and it read the shared file.
    func testDebugAndReleaseDefaultToDifferentStateDirectories() {
        let debug = FileSessionPersistence.defaultDirectory(debug: true)
        let release = FileSessionPersistence.defaultDirectory(debug: false)

        XCTAssertNotEqual(debug.standardizedFileURL.path, release.standardizedFileURL.path)
        XCTAssertEqual(release.lastPathComponent, "Flight Deck")
        XCTAssertEqual(debug.lastPathComponent, "Flight Deck (Debug)")
        XCTAssertEqual(
            debug.deletingLastPathComponent().path, release.deletingLastPathComponent().path,
            "both live under Application Support; only the leaf differs")
    }

    /// The test host is itself a Debug build, so the no-argument default must be the debug one.
    /// Every caller that writes `?? FileSessionPersistence.defaultDirectory()` — the search index,
    /// the answer-trigger and control sockets, the intakes root — inherits the split from this.
    func testTheRunningDebugBuildDefaultsToTheDebugDirectory() {
        XCTAssertTrue(SessionDaemon.isDebugBuild, "the unit-test host is expected to be Debug")
        XCTAssertEqual(
            FileSessionPersistence.defaultDirectory().path,
            FileSessionPersistence.defaultDirectory(debug: true).path)
    }

    /// `-FlightDeckStateDir` is the one remaining route by which a Debug build could be handed
    /// the live deck. Refuse it: pointing a debug instance at the live directory is exactly the
    /// collision, however it is spelled.
    func testADebugBuildRefusesAnOverrideNamingTheLiveDirectory() {
        let live = FileSessionPersistence.defaultDirectory(debug: false)
        let debugDir = FileSessionPersistence.defaultDirectory(debug: true)
        let spellings = [
            live.path,
            live.path + "/",
            live.path + "/.",
            live.appendingPathComponent("sub").path + "/..",
            (live.path as NSString).abbreviatingWithTildeInPath,
        ]
        for spelling in spellings {
            let defaults = makeDefaults("refuse-\(spellings.firstIndex(of: spelling)!)")
            defaults.set(spelling, forKey: "FlightDeckStateDir")
            XCTAssertEqual(
                FlightDeckApp.stateDirectory(defaults, debug: true)?.standardizedFileURL.path,
                debugDir.standardizedFileURL.path,
                "a Debug build handed \(spelling) must fall back to its own directory")
        }
    }

    /// The same refusal must follow a symlink to the live directory — the obvious way round a
    /// string comparison.
    func testADebugBuildRefusesASymlinkToTheLiveDirectory() throws {
        let link = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("fd-live-link-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(
            at: link, withDestinationURL: FileSessionPersistence.defaultDirectory(debug: false))
        defer { try? FileManager.default.removeItem(at: link) }

        let defaults = makeDefaults()
        defaults.set(link.path, forKey: "FlightDeckStateDir")

        XCTAssertEqual(
            FlightDeckApp.stateDirectory(defaults, debug: true)?.path,
            FileSessionPersistence.defaultDirectory(debug: true).path)
    }

    /// A scratch directory is still honoured in Debug — that is the supported way to try a
    /// build against a seeded copy of a deck.
    func testADebugBuildStillHonoursAScratchOverride() {
        let defaults = makeDefaults()
        defaults.set("/tmp/flight-deck-state-test", forKey: "FlightDeckStateDir")
        XCTAssertEqual(
            FlightDeckApp.stateDirectory(defaults, debug: true)?.path, "/tmp/flight-deck-state-test")
    }

    /// Release is the live deck; naming its own directory explicitly changes nothing.
    func testAReleaseBuildHonoursAnOverrideNamingTheLiveDirectory() {
        let live = FileSessionPersistence.defaultDirectory(debug: false)
        let defaults = makeDefaults()
        defaults.set(live.path, forKey: "FlightDeckStateDir")
        XCTAssertEqual(FlightDeckApp.stateDirectory(defaults, debug: false)?.path, live.path)
    }

    /// The legacy `sessions.snapshot.v1` blob lives in the defaults domain Debug and Release
    /// share (one bundle id). Migration *removes* it, so a Debug build allowed to migrate would
    /// consume the live user's blob into the debug directory. Only an un-overridden Release
    /// store may migrate.
    func testOnlyAnUnoverriddenReleaseStoreMigratesLegacyDefaults() {
        XCTAssertNotNil(FlightDeckApp.legacyMigrationDefaults(overridden: false, debug: false))
        XCTAssertNil(FlightDeckApp.legacyMigrationDefaults(overridden: false, debug: true))
        XCTAssertNil(FlightDeckApp.legacyMigrationDefaults(overridden: true, debug: false))
        XCTAssertNil(FlightDeckApp.legacyMigrationDefaults(overridden: true, debug: true))
    }
}
