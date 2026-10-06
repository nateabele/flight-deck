import AppKit
import GhosttyKit
import XCTest
@testable import FlightDeck

/// The bundled light/dark terminal theme pair, run through real libghostty config parsing.
///
/// A theme that fails to resolve is silent: libghostty logs a diagnostic nobody reads and the
/// terminal stays on its built-in dark colours, which is exactly what it looked like before
/// the light theme existed. Only reading the resolved colour back catches it.
final class GhosttyThemeTests: XCTestCase {
    private var root: URL!
    private var scratch: URL!

    override func setUpWithError() throws {
        // Config calls need `ghostty_init`, which the shared app performs.
        guard GhosttyApp.shared != nil else {
            throw XCTSkip("GhosttyApp could not initialize in this environment")
        }
        // A space and the `.app` shape of the real install path, which the pair syntax's
        // `,`/`:` splitting must survive.
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GhosttyThemeTests-\(UUID().uuidString)")
        scratch = root.appendingPathComponent("Flight Deck.app/Contents/Resources")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    private func bundledTheme(_ name: String) throws -> URL {
        let source = try XCTUnwrap(
            Bundle(for: type(of: self)).url(forResource: name, withExtension: "conf")
                ?? Bundle.main.url(forResource: name, withExtension: "conf"),
            "\(name).conf missing from the test bundle — see project.yml"
        )
        let copy = scratch.appendingPathComponent("\(name).conf")
        try FileManager.default.copyItem(at: source, to: copy)
        return copy
    }

    /// Loads `line` as a config file, finalizes it, and returns the resolved `background`
    /// as `#rrggbb`, failing on any parse diagnostic.
    private func resolvedBackground(forConfigLine line: String) throws -> String {
        let file = scratch.appendingPathComponent("theme-line.conf")
        try line.write(to: file, atomically: true, encoding: .utf8)
        let config = try XCTUnwrap(ghostty_config_new())
        defer { ghostty_config_free(config) }
        file.path.withCString { ghostty_config_load_file(config, $0) }
        ghostty_config_finalize(config)

        var messages: [String] = []
        for i in 0..<ghostty_config_diagnostics_count(config) {
            if let m = ghostty_config_get_diagnostic(config, i).message {
                messages.append(String(cString: m))
            }
        }
        XCTAssertEqual(messages, [], "libghostty rejected: \(line)")

        var color = ghostty_config_color_s()
        let key = "background"
        XCTAssertTrue(ghostty_config_get(config, &color, key, UInt(key.utf8.count)))
        return String(format: "#%02x%02x%02x", color.r, color.g, color.b)
    }

    /// The exact line `GhosttyApp` ships resolves its light half. libghostty's conditional
    /// state starts light, which is why a freshly finalized config shows the light theme.
    func testThemePairResolvesFromAPathWithSpaces() throws {
        let line = GhosttyApp.themeConfigLine(
            light: try bundledTheme("GhosttyThemeLight").path,
            dark: try bundledTheme("GhosttyThemeDark").path
        )
        XCTAssertEqual(try resolvedBackground(forConfigLine: line), "#ffffff")
    }

    /// The dark theme reproduces libghostty's own default background, so dark mode looks
    /// exactly as it did before themes existed.
    func testDarkThemeMatchesLibghosttyDefault() throws {
        let dark = try bundledTheme("GhosttyThemeDark").path
        XCTAssertEqual(try resolvedBackground(forConfigLine: "theme = \(dark)\n"), "#282c34")
    }

    func testThemeLineEscapesQuotesAndBackslashes() {
        XCTAssertEqual(
            GhosttyApp.themeConfigLine(light: "/a \"b\"", dark: "/c\\d"),
            "theme = light:\"/a \\\"b\\\"\",dark:\"/c\\\\d\"\n"
        )
    }

    func testColorSchemeFollowsAppearance() throws {
        let dark = try XCTUnwrap(NSAppearance(named: .darkAqua))
        let light = try XCTUnwrap(NSAppearance(named: .aqua))
        XCTAssertEqual(GhosttyApp.colorScheme(for: dark), GHOSTTY_COLOR_SCHEME_DARK)
        XCTAssertEqual(GhosttyApp.colorScheme(for: light), GHOSTTY_COLOR_SCHEME_LIGHT)
    }
}
