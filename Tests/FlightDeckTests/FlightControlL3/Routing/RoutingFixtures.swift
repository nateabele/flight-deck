import Foundation
import XCTest

/// Loads L3-R's fixtures from the test bundle's `Fixtures/FlightControlL3/Routing` folder.
enum RoutingFixtures {
    private final class Token {}

    static func data(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle(for: Token.self).url(forResource: name, withExtension: nil,
                                                             subdirectory: "Fixtures/FlightControlL3/Routing"),
                                "missing fixture \(name)")
        return try Data(contentsOf: url)
    }
}
