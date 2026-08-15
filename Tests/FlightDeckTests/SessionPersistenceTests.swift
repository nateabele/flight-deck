import XCTest
@testable import FlightDeck

@MainActor
final class SessionPersistenceTests: XCTestCase {
    final class CapturingProvider: SurfaceProvider {
        var configs: [Ghostty.SurfaceConfiguration] = []
        func makeSurface(_ config: Ghostty.SurfaceConfiguration) -> Ghostty.SurfaceView? {
            configs.append(config)
            return nil
        }
        func tick() {}
    }

    /// In-memory stand-in for UserDefaults.
    final class FakePersistence: SessionPersisting {
        var stored: SessionSnapshot?
        var saveCount = 0
        func load() -> SessionSnapshot? { stored }
        func save(_ snapshot: SessionSnapshot) { stored = snapshot; saveCount += 1 }
    }

    private let allDirsExist: (String) -> Bool = { _ in true }

    /// v1 snapshots predate the field. Decoding must not throw, or the first launch after
    /// this change wipes every tab.
    func testV1SnapshotWithoutPinDecodes() throws {
        let id = UUID()
        let json = """
        {"sessions":[{"id":"\(id.uuidString)","title":"a","workingDirectory":"/w"}],\
        "sessionCounter":1}
        """
        let snapshot = try JSONDecoder().decode(SessionSnapshot.self, from: Data(json.utf8))

        XCTAssertEqual(snapshot.sessions.first?.id, id)
        XCTAssertNil(snapshot.sessions.first?.pinnedConversationID)
    }

    func testRestoreDefaultsAnAbsentPinToTheTabID() {
        let id = UUID()
        let persistence = FakePersistence()
        persistence.stored = SessionSnapshot(
            sessions: [.init(id: id, title: "a", workingDirectory: "/w")],
            selectedSessionID: id,
            sessionCounter: 1
        )
        let store = SessionStore(provider: nil, persistence: persistence)

        XCTAssertTrue(store.restore(directoryExists: allDirsExist))
        XCTAssertEqual(store.repos.first?.sessions.first?.pinnedConversationID, id)
    }

    func testRestoreRoundTripsAPinnedConversation() {
        let id = UUID()
        let conversation = UUID()
        let persistence = FakePersistence()
        persistence.stored = SessionSnapshot(
            sessions: [.init(
                id: id, title: "a", workingDirectory: "/w", pinnedConversationID: conversation
            )],
            selectedSessionID: id,
            sessionCounter: 1
        )
        let store = SessionStore(provider: nil, persistence: persistence)

        XCTAssertTrue(store.restore(directoryExists: allDirsExist))
        XCTAssertEqual(store.repos.first?.sessions.first?.pinnedConversationID, conversation)
        XCTAssertEqual(persistence.stored?.sessions.first?.pinnedConversationID, conversation)
    }

    func testSnapshotRoundTripsThroughUserDefaults() {
        let suiteName = "test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = UserDefaultsSessionPersistence(defaults: defaults)
        XCTAssertNil(store.load())

        let snap = SessionSnapshot(
            sessions: [.init(id: UUID(), title: "a", workingDirectory: "/w")],
            selectedSessionID: nil,
            sessionCounter: 3
        )
        store.save(snap)
        XCTAssertEqual(store.load(), snap)
    }

    func testCreatingASessionPersistsIt() {
        let fake = FakePersistence()
        let store = SessionStore(provider: CapturingProvider(), persistence: fake)
        let session = store.newSession(in: URL(fileURLWithPath: "/work/foo", isDirectory: true))

        XCTAssertEqual(fake.stored?.sessions.map(\.id), [session.id])
        XCTAssertEqual(fake.stored?.selectedSessionID, session.id)
    }

    func testRenamePersistsTheNewTitle() {
        let fake = FakePersistence()
        let store = SessionStore(provider: CapturingProvider(), persistence: fake)
        let session = store.newSession(in: URL(fileURLWithPath: "/work/foo", isDirectory: true))
        store.rename(session.id, to: "renamed")
        XCTAssertEqual(fake.stored?.sessions.first?.title, "renamed")
    }

    func testClosePersistsRemoval() {
        let fake = FakePersistence()
        let store = SessionStore(provider: CapturingProvider(), persistence: fake)
        let session = store.newSession(in: URL(fileURLWithPath: "/work/foo", isDirectory: true))
        store.closeSession(session.id)
        XCTAssertEqual(fake.stored?.sessions.count, 0)
    }

    func testRestoreRebuildsReposGroupedAndOrdered() {
        let fake = FakePersistence()
        let a = UUID(), b = UUID(), c = UUID()
        fake.stored = SessionSnapshot(
            sessions: [
                .init(id: a, title: "one", workingDirectory: "/work/foo"),
                .init(id: b, title: "two", workingDirectory: "/work/bar"),
                .init(id: c, title: "three", workingDirectory: "/work/foo"),
            ],
            selectedSessionID: b,
            sessionCounter: 3
        )

        let store = SessionStore(provider: CapturingProvider(), persistence: fake)
        XCTAssertTrue(store.restore(directoryExists: allDirsExist))

        XCTAssertEqual(store.repos.map(\.displayName), ["foo", "bar"])
        XCTAssertEqual(store.repos[0].sessions.map(\.title), ["one", "three"])
        XCTAssertEqual(store.repos[1].sessions.map(\.title), ["two"])
        XCTAssertEqual(store.selectedSessionID, b)
    }

    func testRestoreResumesEachClaudeConversation() {
        let provider = CapturingProvider()
        let fake = FakePersistence()
        let a = UUID()
        fake.stored = SessionSnapshot(
            sessions: [.init(id: a, title: "one", workingDirectory: "/work/foo")],
            selectedSessionID: a,
            sessionCounter: 1
        )

        let store = SessionStore(provider: provider, persistence: fake)
        XCTAssertTrue(store.restore(directoryExists: allDirsExist))
        XCTAssertEqual(
            provider.configs.first?.initialInput,
            ClaudeSession.resumeCommand(sessionID: a, title: "one")
        )
    }

    func testRestoreDropsSessionsWhoseDirectoryIsGone() {
        let fake = FakePersistence()
        fake.stored = SessionSnapshot(
            sessions: [
                .init(id: UUID(), title: "gone", workingDirectory: "/work/deleted"),
                .init(id: UUID(), title: "kept", workingDirectory: "/work/foo"),
            ],
            selectedSessionID: nil,
            sessionCounter: 2
        )

        let store = SessionStore(provider: CapturingProvider(), persistence: fake)
        XCTAssertTrue(store.restore(directoryExists: { $0 != "/work/deleted" }))
        XCTAssertEqual(store.repos.flatMap(\.sessions).map(\.title), ["kept"])
    }

    /// The counter must survive so a new session cannot collide with a restored name.
    func testRestoredCounterAvoidsTitleCollision() {
        let fake = FakePersistence()
        fake.stored = SessionSnapshot(
            sessions: [.init(id: UUID(), title: "session 3", workingDirectory: "/work/foo")],
            selectedSessionID: nil,
            sessionCounter: 3
        )

        let store = SessionStore(provider: CapturingProvider(), persistence: fake)
        XCTAssertTrue(store.restore(directoryExists: allDirsExist))
        let fresh = store.newSession(in: URL(fileURLWithPath: "/work/foo", isDirectory: true))
        XCTAssertEqual(fresh.title, "session 4")
    }

    /// When the persisted selection's directory is gone, the fallback must be the FIRST
    /// surviving session in restored order — not an arbitrary one. A `Set` here would
    /// make this nondeterministic.
    func testRestoreSelectsFirstSurvivingSessionWhenSelectionIsDropped() {
        let fake = FakePersistence()
        let gone = UUID(), first = UUID(), second = UUID()
        fake.stored = SessionSnapshot(
            sessions: [
                .init(id: gone, title: "gone", workingDirectory: "/work/deleted"),
                .init(id: first, title: "first", workingDirectory: "/work/foo"),
                .init(id: second, title: "second", workingDirectory: "/work/bar"),
            ],
            selectedSessionID: gone,
            sessionCounter: 3
        )

        let store = SessionStore(provider: CapturingProvider(), persistence: fake)
        XCTAssertTrue(store.restore(directoryExists: { $0 != "/work/deleted" }))
        XCTAssertEqual(store.selectedSessionID, first)
    }

    func testRestoreReturnsFalseWhenNothingStored() {
        let store = SessionStore(provider: CapturingProvider(), persistence: FakePersistence())
        XCTAssertFalse(store.restore(directoryExists: allDirsExist))
        XCTAssertTrue(store.repos.isEmpty)
    }

    /// A repeat call must not duplicate sessions. There is no production path that makes
    /// one, but `restore()` stays internal (not `private`) for testability, so nothing
    /// stops a second call from happening; the `repos.isEmpty` guard is what makes that safe.
    func testRestoreIsIdempotent() {
        let fake = FakePersistence()
        fake.stored = SessionSnapshot(
            sessions: [.init(id: UUID(), title: "one", workingDirectory: "/work/foo")],
            selectedSessionID: nil,
            sessionCounter: 1
        )

        let store = SessionStore(provider: CapturingProvider(), persistence: fake)
        XCTAssertTrue(store.restore(directoryExists: allDirsExist))
        XCTAssertFalse(store.restore(directoryExists: allDirsExist), "second call must be a no-op")
        XCTAssertEqual(store.repos.flatMap(\.sessions).map(\.title), ["one"])
    }

    /// `resetState` is only reachable via the production `init(ghostty:resetState:)` path,
    /// so this drives that initializer — but with an injected temp-directory store. Using the
    /// default would write a seeded snapshot over the developer's real
    /// `~/Library/Application Support/Flight Deck/sessions.json`.
    func testResetStateSkipsRestoreEvenWithAStoredSnapshot() throws {
        let dir = try makeTempDir()
        let persistence = FileSessionPersistence(directory: dir, legacyDefaults: nil)
        persistence.save(SessionSnapshot(
            sessions: [.init(id: UUID(), title: "stale", workingDirectory: "/work/foo")],
            selectedSessionID: nil,
            sessionCounter: 1
        ))

        let store = SessionStore(ghostty: nil, resetState: true, persistence: persistence)

        XCTAssertFalse(store.repos.flatMap(\.sessions).map(\.title).contains("stale"))
    }

    /// Pumps the run loop long enough for the shared `WatchClock` to beat at least once,
    /// plus room for the read it schedules off the main actor to come back.
    ///
    /// Requires the store under test to report itself as frontmost (`appIsActive = { true }`):
    /// the clock polls every 500 ms in the foreground but backs off to 2 s when the app is
    /// inactive, and a headless `xctest` run is always inactive. See `WatchClock`.
    private func waitForWatcher() {
        let exp = expectation(description: "watcher tick")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { exp.fulfill() }
        wait(for: [exp], timeout: 3.0)
    }

    /// End-to-end regression for the restore bug: reaches the watcher only through the
    /// store (as production does), so the store↔watcher↔`applyExternalTitle` wiring is
    /// actually exercised. `SessionStore.projectsRoot` exists precisely for this.
    ///
    /// Restores a session whose transcript already contains a `custom-title` line with a
    /// *different* title (as if a rename had happened in a prior run, or the file were
    /// just large) and confirms the first drain does not clobber the restored title with
    /// it. Then appends a genuinely new `custom-title` line and confirms that one IS
    /// applied, proving tailing still works after the seek-to-end seed.
    func testRestoredWatcherDoesNotReplayStaleTitleButStillTailsNewOnes() throws {
        let sid = UUID()
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("swsync-workdir-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }

        let projectsRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("swsync-projects-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: projectsRoot) }

        let transcriptURL = ClaudeSession.transcriptURL(
            sessionID: sid, workingDirectory: workDir.path, projectsRoot: projectsRoot
        )
        try FileManager.default.createDirectory(
            at: transcriptURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )

        func customTitleLine(_ title: String) -> String {
            #"{"type":"custom-title","customTitle":"\#(title)","sessionId":"\#(sid.uuidString.lowercased())"}"#
                + "\n"
        }

        // The transcript already contains a stale rename, as if it were a large
        // pre-existing conversation from a previous run.
        try customTitleLine("stale title").data(using: .utf8)!.write(to: transcriptURL)

        let fake = FakePersistence()
        fake.stored = SessionSnapshot(
            sessions: [.init(id: sid, title: "restored title", workingDirectory: workDir.path)],
            selectedSessionID: sid,
            sessionCounter: 1
        )

        let store = SessionStore(provider: CapturingProvider(), persistence: fake)
        store.projectsRoot = projectsRoot
        // Poll at the foreground cadence: this test asserts on watcher ticks in real time,
        // and a headless run is never frontmost. See `waitForWatcher`.
        store.appIsActive = { true }
        XCTAssertTrue(store.restore(directoryExists: allDirsExist))
        XCTAssertEqual(store.title(of: sid), "restored title")

        waitForWatcher()
        XCTAssertEqual(
            store.title(of: sid), "restored title",
            "the stale on-disk title must not clobber the restored one"
        )

        try (customTitleLine("stale title") + customTitleLine("fresh title"))
            .data(using: .utf8)!.write(to: transcriptURL)

        waitForWatcher()
        XCTAssertEqual(store.title(of: sid), "fresh title")
    }

    // MARK: Recorded activity and unread

    /// Snapshots predating these fields must still decode, or the first launch after this
    /// change wipes every tab — the same rule `testV1SnapshotWithoutPinDecodes` pins.
    func testSnapshotWithoutActivityOrUnreadDecodes() throws {
        let id = UUID()
        let json = """
        {"sessions":[{"id":"\(id.uuidString)","title":"a","workingDirectory":"/w"}],\
        "sessionCounter":1}
        """
        let snapshot = try JSONDecoder().decode(SessionSnapshot.self, from: Data(json.utf8))

        XCTAssertEqual(snapshot.sessions.first?.id, id)
        XCTAssertNil(snapshot.sessions.first?.activity)
        XCTAssertNil(snapshot.sessions.first?.unread)
    }

    func testPersistRecordsEachSessionsActivity() {
        let persistence = FakePersistence()
        let store = SessionStore(provider: CapturingProvider(), persistence: persistence)
        let a = store.newSession(in: URL(fileURLWithPath: "/work/foo", isDirectory: true))
        let b = store.newSession(in: URL(fileURLWithPath: "/work/bar", isDirectory: true))

        store.applyRegistryForTesting([
            a.id: SessionStatus(activity: .busy),
            b.id: SessionStatus(activity: .shell),
        ])
        // `applyRegistryForTesting` only sets the map; force a save the way any mutation would.
        store.selectedSessionID = a.id

        let stored = persistence.stored?.sessions ?? []
        XCTAssertEqual(stored.first(where: { $0.id == a.id })?.activity, "busy")
        XCTAssertEqual(stored.first(where: { $0.id == b.id })?.activity, "shell")
    }

    /// A tab with no `claude` registered records no activity. Absent is not the same as
    /// idle, and restore has to be able to tell them apart.
    func testPersistRecordsNoActivityForASessionWithNoStatus() {
        let persistence = FakePersistence()
        let store = SessionStore(provider: CapturingProvider(), persistence: persistence)
        let a = store.newSession(in: URL(fileURLWithPath: "/work/foo", isDirectory: true))

        XCTAssertNil(persistence.stored?.sessions.first(where: { $0.id == a.id })?.activity)
    }

    // MARK: Restoring unread marks

    func testRestoreSeedsUnreadMarks() {
        let unread = UUID()
        let read = UUID()
        let persistence = FakePersistence()
        persistence.stored = SessionSnapshot(
            sessions: [
                .init(id: unread, title: "a", workingDirectory: "/w", unread: true),
                .init(id: read, title: "b", workingDirectory: "/w"),
            ],
            selectedSessionID: nil,
            sessionCounter: 2
        )
        let store = SessionStore(provider: CapturingProvider(), persistence: persistence)

        XCTAssertTrue(store.restore(directoryExists: allDirsExist))

        XCTAssertTrue(store.unreadIdle.contains(unread))
        XCTAssertFalse(store.unreadIdle.contains(read))
    }

    /// The tab you land on is in front of you, so it comes back read. Seeding happens before
    /// the selection is assigned, whose `didSet` clears the mark — and `observeAppActivation`
    /// would clear it a moment later at launch regardless.
    func testTheRestoredSelectionComesBackRead() {
        let selected = UUID()
        let persistence = FakePersistence()
        persistence.stored = SessionSnapshot(
            sessions: [.init(id: selected, title: "a", workingDirectory: "/w", unread: true)],
            selectedSessionID: selected,
            sessionCounter: 1
        )
        let store = SessionStore(provider: CapturingProvider(), persistence: persistence)

        XCTAssertTrue(store.restore(directoryExists: allDirsExist))

        XCTAssertFalse(store.unreadIdle.contains(selected))
    }

    /// A mark for a session whose directory has gone is not restored, because the session
    /// itself is not — there would be no row to draw it on.
    func testAMarkForADroppedSessionIsNotRestored() {
        let gone = UUID()
        let persistence = FakePersistence()
        persistence.stored = SessionSnapshot(
            sessions: [.init(id: gone, title: "a", workingDirectory: "/gone", unread: true)],
            selectedSessionID: nil,
            sessionCounter: 1
        )
        let store = SessionStore(provider: CapturingProvider(), persistence: persistence)

        store.restore(directoryExists: { _ in false })

        XCTAssertFalse(store.unreadIdle.contains(gone))
    }

    /// The write side of the round trip. Task 2's tests covered `activity`; this covers
    /// `unread`, which is deliberately written as `true`-or-absent rather than `true`/`false`
    /// so the JSON stays readable.
    func testPersistRecordsUnreadAsTrueOrAbsent() {
        let persistence = FakePersistence()
        let store = SessionStore(provider: CapturingProvider(), persistence: persistence)
        let marked = store.newSession(in: URL(fileURLWithPath: "/work/foo", isDirectory: true))
        let clean = store.newSession(in: URL(fileURLWithPath: "/work/bar", isDirectory: true))

        store.markUnreadForTesting([marked.id])
        // `markUnreadForTesting` mutates the set without saving; a selection write persists.
        store.selectedSessionID = clean.id

        let stored = persistence.stored?.sessions ?? []
        XCTAssertEqual(stored.first(where: { $0.id == marked.id })?.unread, true)
        XCTAssertNil(stored.first(where: { $0.id == clean.id })?.unread)
    }

    // MARK: - FileSessionPersistence

    /// Each test gets its own directory so they never touch the real
    /// ~/Library/Application Support/Flight Deck, and never each other.
    private func makeTempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("FlightDeckPersistenceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    /// A defaults domain scoped to one test, so migration tests cannot read or clobber the
    /// real `dev.flightdeck.FlightDeck` domain.
    private func makeScratchDefaults() -> UserDefaults {
        let name = "dev.flightdeck.FlightDeckTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: name) }
        return defaults
    }

    private func makeSnapshot(title: String = "a") -> SessionSnapshot {
        let id = UUID()
        return SessionSnapshot(
            sessions: [.init(id: id, title: title, workingDirectory: "/w")],
            selectedSessionID: id,
            sessionCounter: 1
        )
    }

    func testFileStoreRoundTripsThroughDisk() throws {
        let dir = try makeTempDir()
        let snapshot = makeSnapshot()

        FileSessionPersistence(directory: dir, legacyDefaults: nil).save(snapshot)

        // A *separate* instance, so this reads the file rather than any in-memory state.
        let reloaded = FileSessionPersistence(directory: dir, legacyDefaults: nil).load()
        XCTAssertEqual(reloaded, snapshot)
    }

    func testFileStoreReturnsNilWhenNothingIsStored() throws {
        let dir = try makeTempDir()
        XCTAssertNil(FileSessionPersistence(directory: dir, legacyDefaults: nil).load())
    }

    func testFileStoreCreatesItsDirectory() throws {
        // The real Application Support subdirectory does not exist on a fresh install.
        let dir = try makeTempDir().appendingPathComponent("not/created/yet", isDirectory: true)
        let snapshot = makeSnapshot()

        FileSessionPersistence(directory: dir, legacyDefaults: nil).save(snapshot)

        XCTAssertEqual(FileSessionPersistence(directory: dir, legacyDefaults: nil).load(), snapshot)
    }

    func testMigratesFromDefaultsOnFirstLoadAndClearsTheOldKey() throws {
        let dir = try makeTempDir()
        let defaults = makeScratchDefaults()
        let snapshot = makeSnapshot(title: "carried over")
        defaults.set(try JSONEncoder().encode(snapshot), forKey: FileSessionPersistence.legacyKey)

        let migrated = FileSessionPersistence(directory: dir, legacyDefaults: defaults).load()

        XCTAssertEqual(migrated, snapshot, "the upgrade must not drop the user's tabs")
        XCTAssertNil(
            defaults.data(forKey: FileSessionPersistence.legacyKey),
            "the old key must be cleared so there is one source of truth"
        )
        // And it is now genuinely on disk, not just returned once.
        XCTAssertEqual(FileSessionPersistence(directory: dir, legacyDefaults: nil).load(), snapshot)
    }

    func testFileWinsOverLegacyDefaults() throws {
        let dir = try makeTempDir()
        let defaults = makeScratchDefaults()
        let stale = makeSnapshot(title: "stale defaults copy")
        defaults.set(try JSONEncoder().encode(stale), forKey: FileSessionPersistence.legacyKey)
        let current = makeSnapshot(title: "current file copy")
        FileSessionPersistence(directory: dir, legacyDefaults: nil).save(current)

        let loaded = FileSessionPersistence(directory: dir, legacyDefaults: defaults).load()

        XCTAssertEqual(loaded, current, "a leftover defaults blob must never resurrect old state")
    }

    func testMigrationIsANoOpWhenNothingWasStored() throws {
        let dir = try makeTempDir()
        let defaults = makeScratchDefaults()
        XCTAssertNil(FileSessionPersistence(directory: dir, legacyDefaults: defaults).load())
    }

}
