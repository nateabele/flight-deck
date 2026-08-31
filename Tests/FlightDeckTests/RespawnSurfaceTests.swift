import XCTest
@testable import FlightDeck

@MainActor
final class RespawnSurfaceTests: XCTestCase {
    private struct Display: DisplayInspecting { var isDrawable: Bool }
    private var tmp: URL { URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true) }

    private final class FakePersistence: SessionPersisting {
        var stored: SessionSnapshot?
        func load() -> SessionSnapshot? { stored }
        func save(_ snapshot: SessionSnapshot) { stored = snapshot }
    }

    // Same reason as `DisplayDrawableGuardTests`: `SessionStore.provider` is `weak`, so an
    // unretained `StubProvider` would deallocate immediately.
    private var retainedProviders: [StubProvider] = []

    private func store(
        drawable: Bool, persistence: SessionPersisting? = nil, provider: SurfaceProvider? = nil
    ) -> SessionStore {
        let s = SessionStore(provider: provider, persistence: persistence)
        s.display = Display(isDrawable: drawable)
        return s
    }

    /// A store carrying one inert tab, built with zero production support: a `StubProvider` —
    /// present, but its `makeSurface` always returns nil, the same idiom
    /// `DisplayDrawableGuardTests` uses — restored from a one-session snapshot. `restore()` is
    /// deliberately unguarded on `canCreateTerminal`, so the tab is inserted regardless of
    /// `drawable`; the stub's nil surface means nothing is ever recorded in the registry, so
    /// `hasShellProcess(for:)` reads false — exactly what a relaunch during sleep leaves
    /// behind. A provider being present (unlike a bare `provider: nil` store) is what keeps
    /// `canCreateTerminal` genuinely sensitive to `display`.
    private func inertStore(drawable: Bool) -> (store: SessionStore, id: UUID) {
        let id = UUID()
        let entry = SessionSnapshot.Entry(id: id, title: "inert", workingDirectory: tmp.path)
        let persistence = FakePersistence()
        persistence.stored = SessionSnapshot(
            sessions: [entry], selectedSessionID: nil, sessionCounter: 1
        )
        let provider = StubProvider()
        retainedProviders.append(provider)
        let s = store(drawable: drawable, persistence: persistence, provider: provider)
        _ = s.restore()
        return (s, id)
    }

    /// Refused while the display cannot be drawn to — retrying there is exactly how the inert
    /// tab was produced in the first place.
    func testRefusesWhenTheDisplayCannotBeDrawnTo() {
        let (s, id) = inertStore(drawable: false)
        XCTAssertEqual(s.respawnSurface(for: id), .displayAsleep)
    }

    func testUnknownSessionIsReportedAsSuch() {
        XCTAssertEqual(store(drawable: true).respawnSurface(for: UUID()), .unknownSession)
    }

    /// The discrimination that matters, and the one no existing test makes: an inert tab HAS a
    /// surface. Only the registry tells the two apart.
    func testHealthIsTheRegistryNotTheSurface() {
        let (s, id) = inertStore(drawable: true)
        XCTAssertFalse(s.hasShellProcess(for: id))
    }
}
