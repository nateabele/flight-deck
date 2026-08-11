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

    /// `resetState` is only reachable via the production `init(ghostty:resetState:)` path
    /// (it needs `UserDefaultsSessionPersistence`'s real-defaults storage, which the
    /// designated `init(provider:persistence:)` used elsewhere in this file can bypass
    /// entirely). Save/restore the raw key around the assertion so this doesn't leak
    /// state into other tests or pollute the real domain permanently.
    func testResetStateSkipsRestoreEvenWithAStoredSnapshot() {
        let defaults = UserDefaults.standard
        let key = "sessions.snapshot.v1"
        let previous = defaults.data(forKey: key)
        defer {
            if let previous {
                defaults.set(previous, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }

        let stale = SessionSnapshot(
            sessions: [.init(id: UUID(), title: "stale", workingDirectory: "/work/foo")],
            selectedSessionID: nil,
            sessionCounter: 1
        )
        defaults.set(try! JSONEncoder().encode(stale), forKey: key)

        let store = SessionStore(ghostty: nil, resetState: true)

        XCTAssertFalse(store.repos.flatMap(\.sessions).map(\.title).contains("stale"))
    }

    /// Pumps the run loop long enough for a `TranscriptWatcher`'s real 500ms polling
    /// timer to fire at least once.
    private func waitForWatcher() {
        let exp = expectation(description: "watcher tick")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { exp.fulfill() }
        wait(for: [exp], timeout: 2.0)
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
}
