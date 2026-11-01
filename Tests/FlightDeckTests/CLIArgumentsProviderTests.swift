import FleetKit
import XCTest

/// `provider check DIR`: a local command, parsed here and run by `main.swift` without a socket.
final class CLIArgumentsProviderTests: XCTestCase {
    private func parse(_ s: String...) throws -> CLIInvocation { try CLIArguments.parse(s) }

    func testProviderCheckParsesTheFolder() throws {
        XCTAssertEqual(try parse("provider", "check", "/p/x").command, .providerCheck(dir: "/p/x", runSamples: false))
    }

    func testProviderCheckAcceptsTheFolderBeforeOrAfterJSON() throws {
        XCTAssertEqual(try parse("provider", "check", "--json", "x").command, .providerCheck(dir: "x", runSamples: false))
    }

    func testProviderCheckRunSamplesFlag() throws {
        XCTAssertEqual(try parse("provider", "check", "x", "--run-samples").command,
                       .providerCheck(dir: "x", runSamples: true))
        XCTAssertEqual(try parse("provider", "check", "--run-samples", "x").command,
                       .providerCheck(dir: "x", runSamples: true))
        XCTAssertTrue(CLIHelp.text(for: "provider check").contains("--run-samples"))
    }

    func testProviderCheckWithoutAFolderIsUsageError() {
        XCTAssertThrowsError(try parse("provider", "check")) {
            XCTAssertTrue(($0 as? CLIUsageError)?.message.contains("provider check") == true)
        }
    }

    func testProviderCheckWithTwoFoldersIsUsageError() {
        XCTAssertThrowsError(try parse("provider", "check", "a", "b"))
    }

    func testProviderCheckUnknownFlagIsUsageError() {
        XCTAssertThrowsError(try parse("provider", "check", "a", "--frob"))
    }

    func testProviderUnknownSubcommandIsUsageError() {
        XCTAssertThrowsError(try parse("provider", "frobnicate")) {
            XCTAssertTrue(($0 as? CLIUsageError)?.message.contains("frobnicate") == true)
        }
        XCTAssertThrowsError(try parse("provider"))
    }

    func testProviderHasHelpPages() {
        XCTAssertNotNil(CLIHelp.topic(for: ["provider", "check"]))
        XCTAssertNotNil(CLIHelp.topic(for: ["provider"]))
        XCTAssertTrue(CLIHelp.text(for: "provider check").contains("2 usage error"))
    }
}
