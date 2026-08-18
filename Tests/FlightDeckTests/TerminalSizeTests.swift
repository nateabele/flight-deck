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
}
