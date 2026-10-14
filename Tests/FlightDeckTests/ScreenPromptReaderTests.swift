@testable import FleetKit
import XCTest
@testable import FlightDeck

/// Naming a dialog from the terminal screen alone — `ScreenPromptReader` and the
/// `ChoiceDialog.menu` reading under it.
///
/// **The three login screens are captured, not authored** (`Fixtures/Claude/login.captured
/// .provenance.json`: claude 2.1.296 in a pty, rendered with pyte). Everything built inline with
/// `viewport(_:)` or by editing a capture is authored, and says so: the rule this suite shares
/// with `ChoiceDialogTests` is that when a capture disagrees with the code the code is wrong.
///
/// The bias is the same too. A screen this cannot read is `nil` — "Waiting for you", exactly as
/// before this existed — and never a card for the wrong thing.
final class ScreenPromptReaderTests: XCTestCase {
    private func captured(_ name: String) throws -> String {
        try TimelineFixtureTests.text(name, in: "Claude")
    }

    private func viewport(_ lines: [String]) -> String { lines.joined(separator: "\n") }

    private func menu(_ screen: String) -> ChoiceDialog.Menu? {
        ChoiceDialog.menu(inViewport: screen, marker: ChoiceDialog.claudeMarker)
    }

    // MARK: - The login-method menu (captured)

    func testTheLoginMethodMenuIsReadWithItsRowsItsCursorAndItsQuestion() throws {
        let screen = try captured("login-method.captured")
        let menu = try XCTUnwrap(self.menu(screen))

        XCTAssertEqual(menu.prompt, "Select login method:",
                       "the nearest non-blank line above the list, past one blank line")
        XCTAssertEqual(menu.focused, 0, "claude opens every menu with the cursor on row 0")
        XCTAssertEqual(menu.rows.map(\.label), [
            "Claude account with subscription · Pro, Max, Team, or Enterprise",
            "Anthropic Console account · API usage billing",
            "3rd-party platform · Amazon Bedrock, Microsoft Foundry, Google Vertex AI",
        ])
        XCTAssertTrue(menu.rows.allSatisfy { $0.detail == nil })
    }

    func testTheLoginMethodMenuBecomesASingleSelectQuestionWithAScreenIdentity() throws {
        let open = try XCTUnwrap(ScreenPromptReader.read(
            inViewport: try captured("login-method.captured")))
        guard case .question(let call, let questions) = open else {
            return XCTFail("a menu is a question, got \(open)")
        }
        XCTAssertTrue(ScreenPromptID.isMenu(call), call)
        XCTAssertEqual(questions.count, 1)
        XCTAssertEqual(questions[0].question, "Select login method:")
        XCTAssertFalse(questions[0].multiSelect)
        XCTAssertEqual(questions[0].options.count, 3)
        XCTAssertTrue(questions[0].isAnswerable)
    }

    /// The interlock the answer path leans on, over the same capture: the rows the reader
    /// returned are the rows `row(_:reads:)` confirms, so a label the phone echoes back is one
    /// this screen holds.
    func testEveryRowTheReaderReturnsIsConfirmedByTheInterlock() throws {
        let screen = try captured("login-method.captured")
        let menu = try XCTUnwrap(self.menu(screen))
        for (index, row) in menu.rows.enumerated() {
            XCTAssertTrue(ChoiceDialog.row(index, reads: row.label, inViewport: screen,
                                           marker: ChoiceDialog.claudeMarker), row.label)
        }
        XCTAssertEqual(ChoiceDialog.focusedRow(inViewport: screen, marker: ChoiceDialog.claudeMarker), 0)
    }

    // MARK: - The rate-limit menu (captured)

    /// **The menu claude opens by itself on a usage limit** (`rate-limit.captured.provenance.json`,
    /// opened by typing `/rate-limit-options`). The echoed `❯ /rate-limit-options` above it carries
    /// the marker with no number, which must not become a row or the cursor.
    func testTheRateLimitMenuIsReadWithItsRowsItsCursorAndItsQuestion() throws {
        let screen = try captured("rate-limit-options.captured")
        let menu = try XCTUnwrap(self.menu(screen))

        XCTAssertEqual(menu.prompt, "What do you want to do?")
        XCTAssertEqual(menu.focused, 0)
        XCTAssertEqual(menu.rows.map(\.label),
                       ["Stop and wait for limit to reset", "Switch to usage credits"])
        for (index, row) in menu.rows.enumerated() {
            XCTAssertTrue(ChoiceDialog.row(index, reads: row.label, inViewport: screen,
                                           marker: ChoiceDialog.claudeMarker), row.label)
        }

        let open = try XCTUnwrap(ScreenPromptReader.read(inViewport: screen))
        guard case .question(let call, let questions) = open else {
            return XCTFail("a menu is a question, got \(open)")
        }
        XCTAssertTrue(ScreenPromptID.isMenu(call), call)
        XCTAssertEqual(questions.map(\.question), ["What do you want to do?"])
        XCTAssertTrue(questions[0].isAnswerable)
    }

    // MARK: - Identity

    /// **A change of menu is a wire change; a cursor move is not.** The id is a digest of the
    /// prompt and the labels, so it must not move when someone presses an arrow at the keyboard
    /// — that would retire the phone's card on every keystroke — and must move when the menu is
    /// replaced by another.
    func testTheIdentityIgnoresTheCursorAndFollowsTheWords() throws {
        let screen = try captured("login-method.captured")
        let original = try XCTUnwrap(ScreenPromptReader.read(inViewport: screen)).callID

        // Authored: the capture with the cursor moved down one row.
        let moved = screen
            .replacingOccurrences(of: " ❯ 1. Claude", with: "   1. Claude")
            .replacingOccurrences(of: "   2. Anthropic", with: " ❯ 2. Anthropic")
        XCTAssertNotEqual(moved, screen, "the edit must have taken, or this proves nothing")
        XCTAssertEqual(try XCTUnwrap(ScreenPromptReader.read(inViewport: moved)).callID, original)

        // Authored: one label changed.
        let relabelled = screen.replacingOccurrences(of: "Anthropic Console account", with: "Another account")
        XCTAssertNotEqual(try XCTUnwrap(ScreenPromptReader.read(inViewport: relabelled)).callID, original)

        // Authored: a different question over the same rows.
        let asked = screen.replacingOccurrences(of: "Select login method:", with: "Pick a method:")
        XCTAssertNotEqual(try XCTUnwrap(ScreenPromptReader.read(inViewport: asked)).callID, original)
    }

    func testTheIdentityIsStableAcrossProcessesBecauseItIsNotHashValue() {
        // Pinned to a literal: `Hasher` is seeded per launch, and an id that changed on every
        // restart would be a new dialog to a phone each time the Mac relaunched.
        XCTAssertEqual(ScreenPromptID.menu(prompt: "Select login method:", labels: ["a", "b"]),
                       ScreenPromptID.menu(prompt: "Select login method:", labels: ["a", "b"]))
        XCTAssertEqual(ScreenPromptID.fnv1a64Hex(""), "cbf29ce484222325")
        XCTAssertEqual(ScreenPromptID.fnv1a64Hex("a"), "af63dc4c8601ec8c")
        XCTAssertNotEqual(ScreenPromptID.menu(prompt: nil, labels: ["ab", "c"]),
                          ScreenPromptID.menu(prompt: nil, labels: ["a", "bc"]),
                          "field boundaries are part of the identity")
    }

    // MARK: - No card (captured and authored)

    /// **The out-of-scope screen, and the rule that it makes no card.** The first-run theme
    /// picker draws `❯ ✔ Dark mode` with no numbers, so there is no numbered run to read; the
    /// diff preview beneath it draws `  1  function greet() {` — a number with no dot — which is
    /// not a row either. Nothing here may widen to take it, and nothing does.
    func testTheThemePickerProducesNoCard() throws {
        let screen = try captured("login-theme-picker.captured")
        XCTAssertNil(menu(screen))
        XCTAssertNil(ScreenPromptReader.read(inViewport: screen))
        XCTAssertNil(ChoiceDialog.focusedRow(inViewport: screen, marker: ChoiceDialog.claudeMarker),
                     "and the interlock agrees there is no list to drive")
    }

    /// Authored. The idle composer draws `❯` too; a numbered list in an old answer above it is
    /// scrollback, not the thing the session is blocked on.
    func testANumberedListAboveALiveComposerIsNotAMenu() {
        let screen = viewport([
            " Here are the options:",
            "   1. Fast",
            "   2. Careful",
            "",
            "────────────────────────────────────────",
            "❯ ",
            "────────────────────────────────────────",
        ])
        XCTAssertNil(menu(screen))
        // And with the list's own row marked but a composer below it, still not a menu.
        let marked = screen.replacingOccurrences(of: "   1. Fast", with: " ❯ 1. Fast")
        XCTAssertNil(menu(marked))
    }

    /// Authored. A list claude's own prose draws has no cursor at all, which is `focusedRow`'s
    /// "not a dialog anyone is being offered".
    func testANumberedListWithNoCursorIsNotAMenu() {
        XCTAssertNil(menu(viewport([" Steps:", "   1. Fast", "   2. Careful"])))
    }

    /// Authored. A checkbox list is a multiSelect question with an order of operations, not a
    /// menu — and its unnumbered action row is no reason to guess one.
    func testACheckboxListIsNotAMenu() throws {
        let screen = try captured("question-checkbox.captured")
        XCTAssertNil(menu(screen))
    }

    /// Authored: a menu with a blank-padded or absent question still reads, with no prompt.
    func testAMenuWithNoLineAboveItHasNoPromptAndStillReads() throws {
        let menu = try XCTUnwrap(self.menu(viewport([" ❯ 1. Yes", "   2. No"])))
        XCTAssertNil(menu.prompt)
        let open = try XCTUnwrap(ScreenPromptReader.read(inViewport: viewport([" ❯ 1. Yes", "   2. No"])))
        guard case .question(_, let questions) = open else { return XCTFail() }
        XCTAssertEqual(questions[0].question, ScreenPromptReader.unnamedMenuQuestion)
    }

    func testAFullWidthRuleAboveTheListIsNotAQuestion() throws {
        let menu = try XCTUnwrap(self.menu(viewport([
            "────────────────────────────────────────", " ❯ 1. Yes", "   2. No",
        ])))
        XCTAssertNil(menu.prompt)
    }

    // MARK: - The sign-in screen (captured)

    func testThePasteCodeScreenIsASignInWithItsWrappedUrlRejoined() throws {
        let open = try XCTUnwrap(ScreenPromptReader.read(
            inViewport: try captured("login-paste-code.captured")))
        guard case .signIn(let call, let url) = open else {
            return XCTFail("expected a sign-in, got \(open)")
        }
        XCTAssertTrue(ScreenPromptID.isSignIn(call), call)
        XCTAssertEqual(url, "https://claude.com/cai/oauth/authorize?code=true"
            + "&client_id=9d1c250a-e61b-44d9-88ed-5944d1962f5e&response_type=code"
            + "&redirect_uri=https%3A%2F%2Fplatform.claude.com%2Foauth%2Fcode%2Fcallback"
            + "&scope=org%3Acreate_api_key+user%3Aprofile+user%3Ainference"
            + "+user%3Asessions%3Aclaude_code+user%3Amcp_servers+user%3Afile_upload+user%3Aplugins"
            + "&code_challenge=FAKE-code-challenge-PLACEHOLDER-00000000000&code_challenge_method=S256"
            + "&state=FAKE-state-PLACEHOLDER-00000000000000000000",
            "every one of the four wrapped lines, joined with no separator")
        XCTAssertFalse(url.contains(" "))
    }

    func testTheSignInIdentityIsADigestOfTheStateNeverTheState() throws {
        let open = try XCTUnwrap(ScreenPromptReader.read(
            inViewport: try captured("login-paste-code.captured")))
        XCTAssertEqual(open.callID, ScreenPromptID.signIn(
            state: "FAKE-state-PLACEHOLDER-00000000000000000000"))
        XCTAssertFalse(open.callID.contains("PLACEHOLDER"))
        XCTAssertTrue(open.callID.hasPrefix("signin:"))
    }

    /// Authored: the same capture with a second login attempt's state is a different dialog.
    func testASecondLoginAttemptIsADifferentSignIn() throws {
        let screen = try captured("login-paste-code.captured")
        let other = screen.replacingOccurrences(of: "FAKE-state-PLACEHOLDER-0", with: "FAKE-state-PLACEHOLDER-1")
        XCTAssertNotEqual(try XCTUnwrap(ScreenPromptReader.read(inViewport: other)).callID,
                          try XCTUnwrap(ScreenPromptReader.read(inViewport: screen)).callID)
    }

    /// **The browser's own URL redirects to localhost, which is a dead end on a phone.** claude
    /// opens that one itself; the on-screen one is the usable one, and a screen that shows the
    /// other kind is no card. Authored by editing the capture's redirect_uri.
    func testALocalhostRedirectIsRefused() throws {
        let screen = try captured("login-paste-code.captured")
        for redirect in ["http%3A%2F%2Flocalhost%3A54545%2Fcallback",
                         "http%3A%2F%2F127.0.0.1%3A54545%2Fcallback",
                         "https%3A%2F%2Flocalhost%2Fcallback"] {
            // The wrap fell inside this value in the capture, so the edit rebuilds the line.
            let edited = screen
                .replacingOccurrences(of: "https%3A%2F%\n2Fplatform.claude.com%2Foauth%2Fcode%2Fcallback",
                                      with: redirect)
            XCTAssertNotEqual(edited, screen)
            XCTAssertNil(ScreenPromptReader.signIn(inViewport: edited), redirect)
        }
    }

    /// Authored. The URL's last line scrolled off, taking the `state` — the identity — with it.
    func testAUrlCutOffBeforeItsStateIsNotASignIn() throws {
        let screen = try captured("login-paste-code.captured")
        let cut = screen.components(separatedBy: "\n")
            .filter { !$0.hasPrefix("e=FAKE-state") }
            .joined(separator: "\n")
            .replacingOccurrences(of: "&stat\n", with: "\n")
        XCTAssertNil(ScreenPromptReader.signIn(inViewport: cut))
    }

    func testThePasteCodePromptWithNoUrlIsNotASignIn() throws {
        XCTAssertNil(ScreenPromptReader.signIn(inViewport: viewport([
            " Browser didn't open? Use the url below to sign in (c to copy)", "", "",
            " Paste code here if prompted >",
        ])))
    }

    func testAnAuthorizeUrlOnAnotherHostIsRefused() throws {
        let screen = try captured("login-paste-code.captured")
        let elsewhere = screen.replacingOccurrences(of: "https://claude.com/", with: "https://claude.com.evil.example/")
        XCTAssertNotEqual(elsewhere, screen)
        XCTAssertNil(ScreenPromptReader.signIn(inViewport: elsewhere))
        let http = screen.replacingOccurrences(of: "https://claude.com/", with: "http://claude.com/")
        XCTAssertNil(ScreenPromptReader.signIn(inViewport: http))
    }

    /// The two login screens cannot be confused: the sign-in has no numbered list, and the menu
    /// has no URL.
    func testEachLoginScreenIsOnlyItsOwnKind() throws {
        let method = try captured("login-method.captured")
        let paste = try captured("login-paste-code.captured")
        XCTAssertNil(ScreenPromptReader.signIn(inViewport: method))
        XCTAssertNil(ScreenPromptReader.menu(inViewport: paste))
    }
}
