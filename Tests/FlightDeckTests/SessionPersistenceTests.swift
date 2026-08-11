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
        let defaults = UserDefaults(suiteName: "test.\(UUID().uuidString)")!
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

    func testRestoreReturnsFalseWhenNothingStored() {
        let store = SessionStore(provider: CapturingProvider(), persistence: FakePersistence())
        XCTAssertFalse(store.restore(directoryExists: allDirsExist))
        XCTAssertTrue(store.repos.isEmpty)
    }
}
