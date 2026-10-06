import XCTest
import IntakeKit

/// The refresh agent reads the open web, so its command is the one place to get isolation
/// right: web search and fetch exist, nothing that runs code or touches files does, no MCP
/// server loads, and nobody is asked a question. Its answer is schema-bound JSON parsed the
/// same way every other headless claude run's is.
final class IndexExtractionTests: XCTestCase {
    private var terminalBench: IndexSource { IndexSourceRegistry.initial.first { $0.id == "terminal-bench" }! }

    private func value(after flag: String, in args: [String]) -> String? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    func testCommandGrantsOnlyWebTools() {
        let cmd = IndexExtraction.command(prompt: "P", settings: IndexAgentSettings(model: "haiku", effort: "low", tokenCap: 10))
        XCTAssertEqual(cmd.executable, "claude")
        XCTAssertEqual(value(after: "-p", in: cmd.arguments), "P")
        XCTAssertEqual(value(after: "--model", in: cmd.arguments), "haiku")
        XCTAssertEqual(value(after: "--effort", in: cmd.arguments), "low")
        XCTAssertEqual(value(after: "--tools", in: cmd.arguments), "WebSearch WebFetch")
        XCTAssertEqual(value(after: "--allowedTools", in: cmd.arguments), "WebSearch WebFetch")
        XCTAssertEqual(value(after: "--permission-mode", in: cmd.arguments), "dontAsk")
        XCTAssertEqual(value(after: "--json-schema", in: cmd.arguments), IndexExtraction.schemaJSON)
        XCTAssertEqual(value(after: "--output-format", in: cmd.arguments), "stream-json")
        for flag in ["--restricted", "--strict-mcp-config", "--verbose"] { XCTAssertTrue(cmd.arguments.contains(flag), flag) }
        XCTAssertTrue(value(after: "--disallowedTools", in: cmd.arguments)?.contains("Bash") == true)
        XCTAssertEqual(cmd.unsetEnvironment, ["CLAUDE_CODE_CHILD_SESSION", "CLAUDECODE"])
    }

    func testSchemaRequiresEveryRowField() throws {
        let schema = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(IndexExtraction.schemaJSON.utf8)) as? [String: Any])
        let rows = try XCTUnwrap((schema["properties"] as? [String: Any])?["rows"] as? [String: Any])
        let items = try XCTUnwrap(rows["items"] as? [String: Any])
        XCTAssertEqual(Set(items["required"] as? [String] ?? []),
                       ["benchmarkModel", "score", "unit", "url", "retrievedAt", "quotedFigure"])
    }

    func testPromptCarriesTheSourceAndTheCatalog() {
        let prompt = IndexExtraction.prompt(source: terminalBench, catalogs: IndexFixtures.catalogs())
        XCTAssertTrue(prompt.contains("(id terminal-bench)"))
        XCTAssertTrue(prompt.contains(terminalBench.url))
        XCTAssertTrue(prompt.contains(terminalBench.howToRead))
        XCTAssertTrue(prompt.contains(#"Unit: report every score in "percent"."#))
        XCTAssertTrue(prompt.contains("- codex/gpt-6-sol (GPT-6 Sol)"))
        XCTAssertTrue(IndexExtraction.prompt(source: terminalBench, catalogs: AdapterCatalogs([])).contains("(none listed yet)"))
    }

    func testParseReadsStructuredOutputFromTheStream() throws {
        let json = IndexFixtures.payloadJSON("terminal-bench", [("GPT-6 Sol (high)", 61.3)])
        let payload = try IndexExtraction.parse(stdout: IndexFixtures.stream(json))
        XCTAssertEqual(payload.source, "terminal-bench")
        XCTAssertEqual(payload.rows.first?.quotedFigure, "61.3%")
    }

    func testParseRejectsAnErrorResult() {
        XCTAssertThrowsError(try IndexExtraction.parse(stdout: IndexFixtures.stream("{}", isError: true)))
    }
}
