import FleetKit
import XCTest
@testable import FlightDeck

final class CodexScreenPromptTests: XCTestCase {
    func testHeredocApprovalIncludesReasonEnvironmentAndWholeCommand() throws {
        let screen = """
        Would you like to run the following command?
        Environment: local
        Reason: May I identify only the Execute agent?

        $ python3 - <<'PY'
        print('processes')
        PY

        › 1. Yes, proceed (y)
          2. No (esc)

        Press enter to confirm or esc to cancel
        """
        guard case .question(_, let questions) = try XCTUnwrap(CodexScreenPrompt.read(screen)) else { return XCTFail() }
        XCTAssertTrue(questions[0].question.contains("May I identify only"))
        XCTAssertTrue(questions[0].question.contains("Environment: local"))
        XCTAssertTrue(questions[0].question.contains("print('processes')"))
        XCTAssertNotEqual(CodexScreenPrompt.read(screen)?.callID,
                          CodexScreenPrompt.read(screen.replacingOccurrences(of: "print('processes')", with: "print('other command')"))?.callID)
    }
    private func capture(_ name: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("Fixtures/Codex/\(name).captured.txt"), encoding: .utf8)
    }

    func testCapturedTrustAndApprovalMenusBecomePhoneOffers() throws {
        for name in ["workspace-trust", "approval-command", "approval-command-row1"] {
            guard case .question(let call, let questions) = try XCTUnwrap(CodexScreenPrompt.read(capture(name))) else { return XCTFail("missing menu") }
            XCTAssertTrue(ScreenPromptID.isMenu(call))
            XCTAssertGreaterThan(questions[0].options.count, 1)
            XCTAssertFalse(questions[0].allowsOther)
        }
        XCTAssertEqual(try CodexScreenPrompt.read(capture("approval-command"))?.callID,
                       try CodexScreenPrompt.read(capture("approval-command-row1"))?.callID,
                       "moving focus does not change the identity of the menu")
    }

    func testNumberedOutputWithoutADialogFooterIsNotAnOffer() {
        XCTAssertNil(CodexScreenPrompt.read("› 1. First\n  2. Second"))
    }
}
