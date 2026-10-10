import XCTest
@testable import FlightDeck

/// "No menu should blink ever" (the maintainer, 2026-10-09). SwiftUI reconciles the whole main menu
/// whenever a `Commands` body is re-evaluated — on any observed publish or focused-value change,
/// even with identical output — and the reconciliation is what removed the Tools menu
/// (`AppKitMenuSlot` has the measurements; `scripts/test-menu-bar.sh` counts the removals in a
/// real SwiftUI app). So no `Commands` in the app may read state at all. This scans every type
/// that conforms to `Commands` and fails on any property wrapper that subscribes it to
/// something.
final class MenuBarStabilityTests: XCTestCase {
    /// Each of these makes SwiftUI re-evaluate the `Commands` when its source changes.
    private static let subscribing = [
        "@ObservedObject", "@StateObject", "@EnvironmentObject", "@Environment(", "@FocusedValue",
        "@FocusedObject", "@FocusedBinding", "@AppStorage", "@SceneStorage", "@State ", "@Binding",
        "@Bindable", "CurrentProjectObserver",
    ]

    private var sources: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../Sources/FlightDeck").standardized
    }

    /// Every `struct X: Commands { … }` body in the app's sources, by name.
    private func commandsTypes() throws -> [(name: String, file: String, body: String)] {
        let pattern = try NSRegularExpression(pattern: #"struct (\w+)\s*:\s*Commands\s*\{"#)
        var found: [(String, String, String)] = []
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)!
        for case let url as URL in files where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            let ns = text as NSString
            for match in pattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                // The type's body: from its `{` to the matching `}`.
                var depth = 0
                var end = match.range.location + match.range.length - 1
                for index in end..<ns.length {
                    let char = ns.character(at: index)
                    if char == 123 { depth += 1 } else if char == 125 { depth -= 1; if depth == 0 { end = index; break } }
                }
                let body = ns.substring(with: NSRange(location: match.range.location, length: end - match.range.location + 1))
                found.append((ns.substring(with: match.range(at: 1)), url.lastPathComponent, body))
            }
        }
        return found
    }

    func testNoCommandsReadsState() throws {
        let types = try commandsTypes()
        XCTAssertGreaterThanOrEqual(types.count, 9, "the scan found the app's Commands: \(types.map(\.name))")
        for type in types {
            // Comment lines may name the wrappers (to say why they are absent).
            let code = type.body.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
            for wrapper in Self.subscribing where code.contains(wrapper) {
                XCTFail("\(type.name) (\(type.file)) uses \(wrapper): a Commands that reads state rebuilds the menu bar "
                        + "whenever it changes. Put the stateful items in AppKit inside a constant shell (AppKitMenuSlot).")
            }
        }
    }

    /// Every `Commands` the app installs goes through `FlightDeckCommands`, which the menu-bar
    /// harness installs too; a second `.commands { }` would escape both.
    func testTheAppInstallsOnlyFlightDeckCommands() throws {
        let app = try String(contentsOf: sources.appendingPathComponent("FlightDeckApp.swift"), encoding: .utf8)
        let block = try XCTUnwrap(app.range(of: ".commands {").map { app[$0.upperBound...].prefix(200) })
        XCTAssertTrue(block.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("FlightDeckCommands("), String(block))
        XCTAssertEqual(app.components(separatedBy: ".commands {").count, 2, "one .commands block")
    }
}
