import XCTest
@testable import FlightDeck

@MainActor
final class TerminalSizeTests: XCTestCase {
    final class StubProvider: SurfaceProvider {
        func makeSurface(_ config: Ghostty.SurfaceConfiguration) -> Ghostty.SurfaceView? { nil }
        func tick() {}
    }

    final class FakePersistence: SessionPersisting {
        var stored: SessionSnapshot?
        var saveCount = 0
        func load() -> SessionSnapshot? { stored }
        func save(_ snapshot: SessionSnapshot) { stored = snapshot; saveCount += 1 }
    }

    private let allDirsExist: (String) -> Bool = { _ in true }

    /// Builds a store whose surfaces are stubbed and whose size reports are recorded
    /// rather than delivered. `restore()` is called by the caller, not here, so a test can
    /// install the recorder before any session exists.
    private func makeStore(_ persistence: FakePersistence) -> SessionStore {
        SessionStore(provider: StubProvider(), persistence: persistence)
    }

    func testRestoredSessionIsSizedFromTheSnapshot() {
        let id = UUID()
        let persistence = FakePersistence()
        persistence.stored = SessionSnapshot(
            sessions: [.init(id: id, title: "a", workingDirectory: "/w")],
            selectedSessionID: id,
            sessionCounter: 1
        )
        persistence.stored?.terminalSize = .init(width: 742, height: 618)

        let store = makeStore(persistence)
        var reports: [(UUID, CGSize)] = []
        store.sizeReporterOverride = { reports.append(($0, $1)) }

        store.restore(directoryExists: allDirsExist)

        XCTAssertEqual(store.terminalSize, CGSize(width: 742, height: 618))
        XCTAssertEqual(reports.map(\.0), [id])
        XCTAssertEqual(reports.first?.1, CGSize(width: 742, height: 618))

        // `restore()` ends in `persist()`, so the size must survive the round trip it just
        // made — otherwise the field is written once by Task 1 and never again.
        XCTAssertEqual(persistence.stored?.terminalSize, .init(width: 742, height: 618))
    }

    /// A snapshot from before the field existed has no size to restore, so the surface is
    /// sized from the window geometry `RootWindow` declares rather than from libghostty's
    /// 800x600 pixel placeholder.
    func testRestoreWithoutAPersistedSizeUsesTheDefault() {
        let id = UUID()
        let persistence = FakePersistence()
        persistence.stored = SessionSnapshot(
            sessions: [.init(id: id, title: "a", workingDirectory: "/w")],
            selectedSessionID: id,
            sessionCounter: 1
        )

        let store = makeStore(persistence)
        var reports: [(UUID, CGSize)] = []
        store.sizeReporterOverride = { reports.append(($0, $1)) }

        store.restore(directoryExists: allDirsExist)

        XCTAssertEqual(store.terminalSize, SessionStore.defaultTerminalSize)
        XCTAssertEqual(reports.first?.1, SessionStore.defaultTerminalSize)
    }

    /// The `sessions.isEmpty && projects.isEmpty` guard in `restore()` returns before the
    /// session loop, but `seedInitialSession()` still creates a surface afterwards — so the
    /// size has to be seeded above that guard.
    func testSizeIsSeededEvenWhenThereIsNothingToRestore() {
        let persistence = FakePersistence()
        persistence.stored = SessionSnapshot(sessions: [], sessionCounter: 0)
        persistence.stored?.terminalSize = .init(width: 900, height: 500)

        let store = makeStore(persistence)
        store.restore(directoryExists: allDirsExist)

        XCTAssertEqual(store.terminalSize, CGSize(width: 900, height: 500))
    }

    /// A store with three live sessions in one project, the first selected.
    private func makeStoreWithThreeSessions(
        _ persistence: FakePersistence
    ) -> (SessionStore, [UUID]) {
        let ids = [UUID(), UUID(), UUID()]
        persistence.stored = SessionSnapshot(
            sessions: ids.map { .init(id: $0, title: "s", workingDirectory: "/w") },
            selectedSessionID: ids[0],
            sessionCounter: 3
        )
        let store = makeStore(persistence)
        store.restore(directoryExists: allDirsExist)
        return (store, ids)
    }

    func testResizeReachesTheSelectedTabImmediatelyAndTheRestOnSettle() {
        let persistence = FakePersistence()
        let (store, ids) = makeStoreWithThreeSessions(persistence)

        var pending: (() -> Void)?
        store.resizeSettle = { pending = $0 }

        var reports: [(UUID, CGSize)] = []
        store.sizeReporterOverride = { reports.append(($0, $1)) }

        store.terminalSizeDidChange(CGSize(width: 900, height: 700))

        // Only the selected tab, until the drag settles.
        XCTAssertEqual(reports.map(\.0), [ids[0]])

        pending?()

        XCTAssertEqual(Set(reports.map(\.0)), Set(ids))
        XCTAssertTrue(reports.allSatisfy { $0.1 == CGSize(width: 900, height: 700) })
    }

    /// Every frame of a window drag calls this. Only the last size may be broadcast, or a
    /// drag costs one grid-and-scrollback reflow per surface per frame.
    func testOnlyTheFinalSizeOfADragIsBroadcast() {
        let persistence = FakePersistence()
        let (store, ids) = makeStoreWithThreeSessions(persistence)

        var pending: [() -> Void] = []
        store.resizeSettle = { pending.append($0) }
        store.terminalSizeDidChange(CGSize(width: 900, height: 700))
        store.terminalSizeDidChange(CGSize(width: 950, height: 700))

        var reports: [(UUID, CGSize)] = []
        store.sizeReporterOverride = { reports.append(($0, $1)) }
        for work in pending { work() }

        XCTAssertEqual(Set(reports.map(\.0)), Set(ids), "the superseded settle must be dropped")
        XCTAssertTrue(reports.allSatisfy { $0.1 == CGSize(width: 950, height: 700) })
        XCTAssertEqual(reports.count, ids.count, "exactly one report per surface")
    }

    /// "Launch, resize, quit" contains no session mutation, so the size would otherwise be
    /// lost exactly when the user had just chosen it.
    func testASettledResizePersists() {
        let persistence = FakePersistence()
        let (store, _) = makeStoreWithThreeSessions(persistence)

        var pending: (() -> Void)?
        store.resizeSettle = { pending = $0 }
        store.terminalSizeDidChange(CGSize(width: 900, height: 700))
        pending?()

        XCTAssertEqual(
            persistence.stored?.terminalSize, .init(width: 900, height: 700))
    }

    /// A repeat of the current size is the `updateNSView` path, which runs on every published
    /// store change — roughly 2 Hz per live agent.
    func testARepeatedSizeIsIgnored() {
        let persistence = FakePersistence()
        let (store, _) = makeStoreWithThreeSessions(persistence)

        // Installed before the first resize, so this case never schedules a real 150ms
        // dispatch that would outlive it and fire into another test's store.
        var pending: [() -> Void] = []
        store.resizeSettle = { pending.append($0) }
        store.terminalSizeDidChange(CGSize(width: 900, height: 700))
        XCTAssertEqual(pending.count, 1, "the first resize is accepted")

        var reports: [(UUID, CGSize)] = []
        store.sizeReporterOverride = { reports.append(($0, $1)) }
        store.terminalSizeDidChange(CGSize(width: 900, height: 700))

        XCTAssertTrue(reports.isEmpty)
        XCTAssertEqual(pending.count, 1, "no second settle scheduled")
    }

    /// Activation must NOT go through the dedupe: the whole point is that this surface's grid
    /// may be stale while the store's size has not moved.
    func testActivatingATabReportsTheCurrentSizeEvenWhenItHasNotChanged() {
        let persistence = FakePersistence()
        let (store, ids) = makeStoreWithThreeSessions(persistence)

        var reports: [(UUID, CGSize)] = []
        store.sizeReporterOverride = { reports.append(($0, $1)) }

        store.activateTerminalSize(for: ids[2])

        XCTAssertEqual(reports.map(\.0), [ids[2]])
        XCTAssertEqual(reports.first?.1, store.terminalSize)
    }
}
