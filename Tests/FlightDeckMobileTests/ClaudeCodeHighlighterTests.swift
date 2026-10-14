import UIKit
import XCTest
@testable import FlightDeckMobile

final class ClaudeCodeHighlighterTests: XCTestCase {
    private let engine = ClaudeCodeHighlightEngine()

    private func run(_ text: String, _ index: Int?, faint: Bool = false) -> HighlightRun {
        HighlightRun(text: text, paletteIndex: index, bold: false, faint: faint, italic: false, underline: false)
    }

    /// The `jsonc` fence from the "Plugins" conversation, coloured as Claude Code colours it:
    /// keys cyan (attr), strings red, punctuation in the default foreground.
    func testJSONCMatchesClaudeCode() throws {
        let runs = try XCTUnwrap(engine.runs(for: #"{ "id": "dev.flightdeck.codex", "n": 1, "ok": true }"#, language: "jsonc"))
        XCTAssertEqual(runs, [
            run("{ ", nil), run(#""id""#, 6), run(": ", nil), run(#""dev.flightdeck.codex""#, 1),
            run(", ", nil), run(#""n""#, 6), run(": ", nil), run("1", 2), run(", ", nil),
            run(#""ok""#, 6), run(": ", nil), run("true", 4), run(" }", nil),
        ])
    }

    /// `type` is chalk's `cyan.dim`, which the terminal draws faint.
    func testTypesAreFaintCyanAndKeywordsBlue() throws {
        let runs = try XCTUnwrap(engine.runs(for: "let x: Int = 3", language: "swift"))
        XCTAssertEqual(runs.first, run("let", 4))
        XCTAssertTrue(runs.contains(run("Int", 6, faint: true)), "\(runs)")
        XCTAssertTrue(runs.contains(run("3", 2)), "\(runs)")
    }

    /// `title.class` has its own entry (blue) rather than falling back to `title`'s reset.
    func testClassNamesAreBlue() {
        XCTAssertEqual(engine.runs(for: "class Foo {}", language: "python"),
                       [run("class", 4), run(" ", nil), run("Foo", 4), run(" {}", nil)])
    }

    func testNoLanguageIsNotHighlighted() {
        XCTAssertNil(engine.runs(for: "plain", language: nil))
        XCTAssertNil(engine.runs(for: "plain", language: "  "))
    }

    /// An unknown language falls back to plaintext — default foreground, nothing coloured.
    func testUnknownLanguageIsPlainText() {
        XCTAssertEqual(engine.runs(for: "x = 1", language: "no-such-lang"), [run("x = 1", nil)])
    }

    /// Info strings like `ts title="a.ts"` resolve by their leading word.
    func testLeadingWordOfInfoString() throws {
        let runs = try XCTUnwrap(engine.runs(for: "const a = 1", language: "ts title=x"))
        XCTAssertEqual(runs.first, run("const", 4))
    }

    func testPaletteIsTheMacTerminalsThemeFiles() {
        func hex(_ c: UIColor) -> String {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            c.getRed(&r, green: &g, blue: &b, alpha: &a)
            return String(format: "#%02x%02x%02x", Int(round(r * 255)), Int(round(g * 255)), Int(round(b * 255)))
        }
        XCTAssertEqual(hex(TerminalPalette.dark.background), "#282c34")
        XCTAssertEqual(hex(TerminalPalette.dark.foreground), "#ffffff")
        XCTAssertEqual(hex(TerminalPalette.dark.ansi[4]), "#81a2be")
        XCTAssertEqual(hex(TerminalPalette.light.background), "#ffffff")
        XCTAssertEqual(hex(TerminalPalette.light.foreground), "#4d4d4c")
        XCTAssertEqual(hex(TerminalPalette.light.ansi[1]), "#c82829")
    }
}
