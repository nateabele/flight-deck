import FleetKit
import XCTest

/// `intake run`'s own file, mirroring `CLIArgumentsTests`, rather than folding these cases into
/// it: Task 9 is the one place this verb's parsing changes, and it is small enough not to need
/// splitting across the existing file's sections.
final class CLIArgumentsIntakeTests: XCTestCase {
    private func parse(_ s: String...) throws -> CLIInvocation { try CLIArguments.parse(s) }

    func testIntakeRunParsesIDAndRoot() throws {
        let id = UUID()
        XCTAssertEqual(try parse("intake", "run", id.uuidString, "--root", "/x").command,
                       .intakeRun(id: id, root: "/x"))
    }

    func testIntakeRunMissingIDIsUsageError() {
        XCTAssertThrowsError(try parse("intake", "run", "--root", "/x"))
    }

    func testIntakeRunBadUUIDIsUsageError() {
        XCTAssertThrowsError(try parse("intake", "run", "not-a-uuid", "--root", "/x"))
    }

    func testIntakeRunMissingRootIsUsageError() {
        XCTAssertThrowsError(try parse("intake", "run", UUID().uuidString))
    }

    func testIntakeUnknownSubcommandIsUsageError() {
        XCTAssertThrowsError(try parse("intake", "frobnicate")) {
            XCTAssertTrue(($0 as? CLIUsageError)?.message.contains("frobnicate") == true)
        }
    }
}
