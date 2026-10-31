import XCTest
import FleetKit

/// Proves the module boundary itself, which is the thing most likely to be broken by a
/// build-file edit rather than by code: FleetKit is a real framework, it is embedded in the
/// app, and the headless test bundle can resolve it at load time. A plain `import` — not
/// `@testable` — because everything the phone needs is `public`, and a test that reached in
/// through `@testable` would stop noticing when something was accidentally left internal.
final class FleetKitModuleTests: XCTestCase {
    func testTheModuleIsLinkedAndItsPublicSurfaceIsReachable() {
        XCTAssertEqual(FleetKitVersion.wire, 1)
    }
}
