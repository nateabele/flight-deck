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

    /// Unlike `StubProvider`, records what it was handed. Only used by the respawn/font-size
    /// test below, which needs to see the rebuilt `Ghostty.SurfaceConfiguration` rather than
    /// just a health signal.
    private final class CapturingProvider: SurfaceProvider {
        var configs: [Ghostty.SurfaceConfiguration] = []
        func makeSurface(_ config: Ghostty.SurfaceConfiguration) -> Ghostty.SurfaceView? {
            configs.append(config)
            return nil
        }
        func tick() {}
        var defaultFontSize: Float { 12 }
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

    /// The respawn path (~L1023) has its own `config.fontSize = ...` line, separate from
    /// `newSession`'s — nothing here would catch a future edit that deleted only this one.
    /// Not routed through `inertStore`/`store()`, which hardcode `StubProvider`: this needs a
    /// provider that records the config it is handed, and a `PreferencesStore` to source the
    /// size from.
    func testRespawnSeedsTheNewSurfaceFromThePersistedFontSize() {
        let id = UUID()
        let entry = SessionSnapshot.Entry(id: id, title: "inert", workingDirectory: tmp.path)
        let persistence = FakePersistence()
        persistence.stored = SessionSnapshot(
            sessions: [entry], selectedSessionID: nil, sessionCounter: 1
        )
        let preferences = PreferencesStore(persistence: PreferencesStoreTests.MemoryPersistence())
        preferences.preferences.terminalFontSize = 18
        let provider = CapturingProvider()
        let s = SessionStore(provider: provider, persistence: persistence, preferences: preferences)
        s.display = Display(isDrawable: true)
        _ = s.restore()

        _ = s.respawnSurface(for: id)

        XCTAssertEqual(provider.configs.last?.fontSize, 18)
    }
}
