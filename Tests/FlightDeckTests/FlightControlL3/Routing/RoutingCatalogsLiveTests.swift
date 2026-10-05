import XCTest
import IntakeKit
@testable import FlightDeck

/// Spawns a real `codex app-server` and asks for `model/list` — the shape the fixture was
/// trimmed from. Skipped unless `ROUTING_LIVE=1`; spends no tokens.
@MainActor
final class RoutingCatalogsLiveTests: XCTestCase {
    func testCodexListsModelsWithEfforts() async throws {
        guard ProcessInfo.processInfo.environment["ROUTING_LIVE"] == "1" else { throw XCTSkip("set ROUTING_LIVE=1") }
        let (models, schema) = CodexRoutingCatalog.parse(try await CodexRoutingCatalog.liveFetch())
        XCTAssertFalse(models.isEmpty)
        XCTAssertNotNil(schema["effort"])
    }
}
