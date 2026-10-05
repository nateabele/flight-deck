import Foundation
import IntakeKit

/// Loads the shared Level 3 fixtures from the test bundle's `Fixtures/FlightControlL3` folder.
enum L3Fixtures {
    private final class Token {}

    static func data(_ name: String) throws -> Data {
        let bundle = Bundle(for: Token.self)
        guard let url = bundle.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/FlightControlL3") else {
            throw NSError(domain: "L3Fixtures", code: 1, userInfo: [NSLocalizedDescriptionKey: "missing fixture \(name).json"])
        }
        return try Data(contentsOf: url)
    }

    /// `br list --json` wraps rows in `{"issues": […]}`; `br ready`/`br show` return bare arrays.
    /// Accept both so a fixture copied from either command loads.
    static func brRows() throws -> [[String: Any]] { try rows(in: data("br-list-with-blocks")) }

    static func rows(in data: Data) throws -> [[String: Any]] {
        let obj = try JSONSerialization.jsonObject(with: data)
        if let env = obj as? [String: Any], let issues = env["issues"] as? [[String: Any]] { return issues }
        return obj as? [[String: Any]] ?? []
    }

    private static var decoder: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }

    static func kinds() throws -> KindRegistryFile { try decoder.decode(KindRegistryFile.self, from: data("kinds")) }
    static func usageTimeline() throws -> [UsageReading] { try decoder.decode([UsageReading].self, from: data("usage-timeline")) }
}
