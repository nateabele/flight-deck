import XCTest
@testable import HostKit

final class RecipeWriterTests: XCTestCase {
    func testAppendsATableAndKeepsEverythingElseByteForByte() throws {
        let original = DelegateConfigParserTests.specExample + "\n"
        let added = Recipe(host: "mini", run: "swift test", long: true)
        let text = try RecipeWriter.add(name: "unit", recipe: added, to: original)
        XCTAssertTrue(text.hasPrefix(original), "existing content must be untouched:\n\(text)")
        XCTAssertEqual(String(text.dropFirst(original.count)), """

        [recipe.unit]
        host = "mini"
        run = "swift test"
        long = true

        """)
        let config = try DelegateConfigParser.parse(text).config
        XCTAssertEqual(config.recipes["unit"], added)
        XCTAssertEqual(config.recipes.count, 3)
        XCTAssertEqual(config.routes.count, 1)
    }

    func testReplacesOnlyItsOwnTableAndKeepsCommentsAroundIt() throws {
        let original = """
        # Project delegation config — keep this comment.
        default_host = "mini"

        [recipe.unit]   # old one
        run = "make test"
        ports = [
          "[not a header]",
        ]

        [recipe.unit.env]
        OLD = "1"

        # Comment about ui-tests, which must stay with ui-tests.
        [recipe.ui-tests]
        run = "xcodebuild test"   # inline comment kept

        """
        let replacement = Recipe(run: "swift test", env: ["NEW": "2"])
        let text = try RecipeWriter.add(name: "unit", recipe: replacement, to: original)
        XCTAssertEqual(text, """
        # Project delegation config — keep this comment.
        default_host = "mini"

        [recipe.unit]
        run = "swift test"
        env = { NEW = "2" }

        # Comment about ui-tests, which must stay with ui-tests.
        [recipe.ui-tests]
        run = "xcodebuild test"   # inline comment kept

        """)
        let config = try DelegateConfigParser.parse(text).config
        XCTAssertEqual(config.recipes["unit"], replacement)
        XCTAssertEqual(config.recipes["ui-tests"], Recipe(run: "xcodebuild test"))
    }

    func testRoundTripsEveryField() throws {
        let recipe = Recipe(
            host: "linuxbox", run: #"docker compose up --wait "db""#, down: "docker compose down",
            screen: true, long: true, service: true, restartOnSync: true,
            fetch: ["build/**/*.xcresult", "logs/*"], ports: ["5432", "8080:80", "auto:3000"],
            env: ["B": "two", "A": "one\nline", "with space": "x"], apply: .auto, pool: 4)
        let text = try RecipeWriter.add(name: "every thing", recipe: recipe, to: "")
        XCTAssertTrue(text.contains(#"[recipe."every thing"]"#), text)
        XCTAssertTrue(text.contains("ports = [5432, \"8080:80\", \"auto:3000\"]"), text)
        XCTAssertEqual(try DelegateConfigParser.parse(text).config.recipes["every thing"], recipe)
    }

    func testFileWithoutTrailingNewlineStillGetsASeparateTable() throws {
        let text = try RecipeWriter.add(name: "b", recipe: Recipe(run: "b"), to: "[recipe.a]\nrun = \"a\"")
        XCTAssertEqual(text, "[recipe.a]\nrun = \"a\"\n\n[recipe.b]\nrun = \"b\"\n")
    }

    /// Writing into a file that does not parse could only make it worse, and could put a
    /// second copy of a recipe the parser never saw.
    func testRefusesAFileThatDoesNotParse() {
        XCTAssertThrowsError(try RecipeWriter.add(name: "a", recipe: Recipe(run: "a"), to: "[recipe.x\n"))
    }

    func testRejectsAnEmptyOrMultiLineName() {
        XCTAssertThrowsError(try RecipeWriter.add(name: "", recipe: Recipe(run: "a"), to: ""))
        XCTAssertThrowsError(try RecipeWriter.add(name: "a\nb", recipe: Recipe(run: "a"), to: ""))
    }

    func testAddToProjectCreatesTheDirectoryAndFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try RecipeWriter.add(name: "unit", recipe: Recipe(run: "swift test"), projectRoot: root)
        try RecipeWriter.add(name: "lint", recipe: Recipe(run: "swiftlint"), projectRoot: root)
        let config = try XCTUnwrap(DelegateConfigParser.load(projectRoot: root)).config
        XCTAssertEqual(Set(config.recipes.keys), ["unit", "lint"])
    }
}
