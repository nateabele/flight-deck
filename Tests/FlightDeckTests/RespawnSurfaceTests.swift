import XCTest
@testable import FlightDeck

@MainActor
final class RespawnSurfaceTests: XCTestCase {
    private struct Display: DisplayInspecting { var isDrawable: Bool }
    private var tmp: URL { URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true) }

    private func store(drawable: Bool) -> SessionStore {
        let s = SessionStore(provider: nil, persistence: nil)
        s.display = Display(isDrawable: drawable)
        return s
    }

    /// Refused while the display cannot be drawn to — retrying there is exactly how the inert
    /// tab was produced in the first place.
    func testRefusesWhenTheDisplayCannotBeDrawnTo() {
        let s = store(drawable: false)
        let id = s.seedInertSession(in: tmp)
        XCTAssertEqual(s.respawnSurface(for: id), .displayAsleep)
    }

    func testUnknownSessionIsReportedAsSuch() {
        XCTAssertEqual(store(drawable: true).respawnSurface(for: UUID()), .unknownSession)
    }

    /// The discrimination that matters, and the one no existing test makes: an inert tab HAS a
    /// surface. Only the registry tells the two apart.
    func testHealthIsTheRegistryNotTheSurface() {
        let s = store(drawable: true)
        let id = s.seedInertSession(in: tmp)
        XCTAssertFalse(s.hasShellProcess(for: id))
    }
}
