import XCTest
import IntakeKit
@testable import FlightDeck

/// Routing validates a rule's pool and picks a harness's default pool; Capacity is where pools
/// are defined. Until integration routing used a stand-in that only knew `<harness>-default`.
/// This pins that a user-made pool becomes routable and the default stays the default.
final class CapacityPoolDirectoryTests: XCTestCase {
    func testUserPoolsAndDefaultsAreVisibleToRouting() {
        let work = CapacityPool.hosted(id: "codex-subs", label: "Codex subscriptions", harness: "codex", accounts: [UUID()])
        let dflt = CapacityPool.hosted(id: "codex-default", label: "codex — all accounts", harness: "codex", accounts: [])
        let local = CapacityPool.local(id: "ollama-local", label: "Ollama", harness: "opencode", endpoint: "http://localhost:11434", cap: 1)
        let dir = CapacityPoolDirectory { [work, dflt, local] }
        XCTAssertEqual(dir.pools().map { $0.id }, ["codex-subs", "codex-default", "ollama-local"])
        XCTAssertEqual(dir.defaultPool(for: "codex"), "codex-default")
        XCTAssertNil(dir.defaultPool(for: "claude"), "no claude pool configured → no default")
    }
}
