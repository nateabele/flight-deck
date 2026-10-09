import XCTest
@testable import FlightDeck

/// grok's screen grammar, its composer channel and its keyed dialog driver, against the
/// synthetic screens in `Fixtures/Grok/` — rebuilt in the shape the live probe of grok 1.0.30
/// captured (`.superpowers/grok-tui-facts.md` §3–§4), never copied from a real session.
@MainActor
final class GrokScreenTests: XCTestCase {
    static func screen(_ name: String) throws -> String {
        let url = try XCTUnwrap(
            Bundle(for: GrokScreenTests.self).url(forResource: name, withExtension: "txt", subdirectory: "Fixtures/Grok"),
            "missing fixture \(name)")
        return try String(contentsOf: url, encoding: .utf8)
    }

    // MARK: Composer

    func testAnEmptyComposerReadsAsEmptyBecauseGrokDrawsNoPlaceholder() throws {
        let composer = try XCTUnwrap(GrokScreen.composer(inViewport: Self.screen("tui-idle.synthetic")))
        XCTAssertEqual(composer.draft, "")
    }

    func testADraftIsReadOffTheBox() throws {
        let composer = try XCTUnwrap(GrokScreen.composer(inViewport: Self.screen("tui-draft.synthetic")))
        XCTAssertEqual(composer.draft, "half typed thought")
    }

    func testAMultiRowDraftKeepsItsRows() throws {
        let composer = try XCTUnwrap(GrokScreen.composer(inViewport: Self.screen("tui-draft-multiline.synthetic")))
        XCTAssertEqual(composer.draft, "first line\nsecond line")
    }

    func testTheComposerStaysUpWhileATurnRuns() throws {
        XCTAssertEqual(GrokScreen.composer(inViewport: try Self.screen("tui-busy.synthetic"))?.draft, "")
    }

    /// The guard between a person's words and a shell: `│ ❯` with no rounded box around it.
    func testAShellPrintingTheMarkerIsNotAComposer() throws {
        XCTAssertNil(GrokScreen.composer(inViewport: try Self.screen("shell-prompt.synthetic")))
    }

    func testACardReplacesTheComposer() throws {
        XCTAssertNil(GrokScreen.composer(inViewport: try Self.screen("permission-write.synthetic")))
        XCTAssertNil(GrokScreen.composer(inViewport: try Self.screen("question.synthetic")))
    }

    // MARK: Cards

    func testAPermissionCardsRowsAreReadInOrderWithTheirKeys() throws {
        let rows = GrokScreen.cardRows(inViewport: try Self.screen("permission-write.synthetic"))
        XCTAssertEqual(rows.map(\.key), ["1", "2", "3", "4"])
        XCTAssertEqual(rows.map(\.focused), [true, false, false, false])
        XCTAssertEqual(rows[2].label, "Yes")
    }

    func testAQuestionCardKeepsItsFreeTextRow() throws {
        let rows = GrokScreen.cardRows(inViewport: try Self.screen("question.synthetic"))
        XCTAssertEqual(rows.map(\.key), ["1", "2", "z"])
        XCTAssertTrue(GrokScreen.row(rows[0], reads: "Red"))
        XCTAssertFalse(GrokScreen.row(rows[0], reads: "Re"), "a label is matched to a word boundary")
    }

    func testNoCardOnAComposerScreen() throws {
        for name in ["tui-idle.synthetic", "tui-draft.synthetic", "tui-busy.synthetic", "shell-prompt.synthetic"] {
            XCTAssertFalse(GrokScreen.hasCard(inViewport: try Self.screen(name)), name)
        }
        XCTAssertTrue(GrokScreen.hasCard(inViewport: try Self.screen("permission-write.synthetic")))
        XCTAssertTrue(GrokScreen.hasCard(inViewport: try Self.screen("question.synthetic")))
    }
}

/// `GrokTextChannel`: typing through grok's own stash, never through Escape.
@MainActor
final class GrokTextChannelTests: XCTestCase {
    private let channel = GrokTextChannel()

    /// A screen sequence keyed to what the channel sends: Ctrl+S on a draft empties the box,
    /// Return after a stash brings the draft back — or does not, when `autoRestores` is off.
    private final class GrokSpy: TextInjecting {
        enum Action: Equatable { case text(String), ret, control(Character), key(Character), escape, other }
        var actions: [Action] = []
        var viewport: String?
        var afterStash: String?
        var afterReturn: String?
        func readViewport() -> String? { viewport }
        func sendText(_ text: String) { actions.append(.text(text)) }
        func sendReturn() { actions.append(.ret); if let next = afterReturn { viewport = next } }
        func sendControlKey(_ letter: Character) {
            actions.append(.control(letter))
            if letter == "s", let next = afterStash { viewport = next; afterStash = nil }
        }
        func sendCharacterKey(_ character: Character) { actions.append(.key(character)) }
        func sendKillLine() { actions.append(.other) }
        func sendYank() { actions.append(.other) }
        func sendArrowDown() { actions.append(.other) }
        func sendArrowUp() { actions.append(.other) }
        func sendTab() { actions.append(.other) }
        func sendEscape() { actions.append(.escape) }
    }

    private func submit(_ spy: GrokSpy, stillWanted: Bool = true) -> (Bool, Bool?) {
        var finished: Bool?
        let accepted = channel.submit("hello grok", into: spy, settle: { $0() },
                                      stillWanted: { stillWanted }, onFinished: { finished = $0 })
        return (accepted, finished)
    }

    func testAnEmptyComposerIsPastedThenSubmittedWithNothingElse() throws {
        let spy = GrokSpy()
        spy.viewport = try GrokScreenTests.screen("tui-idle.synthetic")
        let (accepted, finished) = submit(spy)
        XCTAssertTrue(accepted)
        XCTAssertEqual(finished, true)
        XCTAssertEqual(spy.actions, [.text("hello grok"), .ret])
    }

    /// The draft goes into grok's stash and grok puts it back after the send by itself, so a
    /// box that is full again after Return gets no second Ctrl+S (which would stash it again).
    func testADraftIsStashedAndLeftForGrokToRestore() throws {
        let spy = GrokSpy()
        spy.viewport = try GrokScreenTests.screen("tui-draft.synthetic")
        spy.afterStash = try GrokScreenTests.screen("tui-idle.synthetic")
        spy.afterReturn = try GrokScreenTests.screen("tui-draft.synthetic")
        let (_, finished) = submit(spy)
        XCTAssertEqual(finished, true)
        XCTAssertEqual(spy.actions, [.control("s"), .text("hello grok"), .ret])
    }

    func testADraftGrokDidNotRestoreIsPoppedBack() throws {
        let spy = GrokSpy()
        spy.viewport = try GrokScreenTests.screen("tui-draft.synthetic")
        spy.afterStash = try GrokScreenTests.screen("tui-idle.synthetic")
        let (_, finished) = submit(spy)
        XCTAssertEqual(finished, true)
        XCTAssertEqual(spy.actions, [.control("s"), .text("hello grok"), .ret, .control("s")])
    }

    /// A stash that did not land leaves the draft in the box; typing then would splice the
    /// message into it.
    func testAStashThatDidNotEmptyTheBoxTypesNothing() throws {
        let spy = GrokSpy()
        spy.viewport = try GrokScreenTests.screen("tui-draft.synthetic")
        let (accepted, finished) = submit(spy)
        XCTAssertTrue(accepted)
        XCTAssertEqual(finished, false)
        XCTAssertEqual(spy.actions, [.control("s")])
    }

    func testASupersededRequestPopsTheStashBack() throws {
        let spy = GrokSpy()
        spy.viewport = try GrokScreenTests.screen("tui-draft.synthetic")
        spy.afterStash = try GrokScreenTests.screen("tui-idle.synthetic")
        let (_, finished) = submit(spy, stillWanted: false)
        XCTAssertEqual(finished, false)
        XCTAssertEqual(spy.actions, [.control("s"), .control("s")])
    }

    func testNoComposerNoTyping() throws {
        for name in ["shell-prompt.synthetic", "permission-write.synthetic"] {
            let spy = GrokSpy()
            spy.viewport = try GrokScreenTests.screen(name)
            XCTAssertFalse(submit(spy).0, name)
            XCTAssertTrue(spy.actions.isEmpty, name)
        }
    }

    /// Escape on an empty grok composer opens the rewind picker; this channel never sends it.
    func testNoPathSendsEscape() throws {
        for (start, stash) in [("tui-idle.synthetic", nil), ("tui-draft.synthetic", "tui-idle.synthetic")] {
            let spy = GrokSpy()
            spy.viewport = try GrokScreenTests.screen(start)
            spy.afterStash = try stash.map(GrokScreenTests.screen)
            _ = submit(spy)
            XCTAssertFalse(spy.actions.contains(.escape), start)
        }
    }

    func testPresenceEmptinessAndTheCardVeto() throws {
        let spy = GrokSpy()
        spy.viewport = try GrokScreenTests.screen("tui-draft.synthetic")
        XCTAssertTrue(channel.hasComposerBox(spy))
        XCTAssertFalse(channel.isComposerEmpty(spy))
        XCTAssertFalse(channel.isKnownNonComposer(spy))
        spy.viewport = try GrokScreenTests.screen("question.synthetic")
        XCTAssertFalse(channel.hasComposerBox(spy))
        XCTAssertTrue(channel.isKnownNonComposer(spy))
        spy.viewport = nil
        XCTAssertFalse(channel.isKnownNonComposer(spy), "unreadable is no veto")
    }
}

/// `GrokDialogDriver`: keys read off the card, Ctrl+C to deny.
@MainActor
final class GrokDialogDriverTests: XCTestCase {
    private let driver = GrokDialogDriver()

    /// The first card of a session focuses always-approve — the reason this driver never
    /// answers with Return. The plain "Yes" is row 3 by its own key.
    func testAllowIsThePlainYesRowsOwnKeyNotTheFocusedRow() throws {
        let screen = try GrokScreenTests.screen("permission-write.synthetic")
        XCTAssertEqual(driver.focusedRow(inViewport: screen), 0)
        XCTAssertEqual(driver.allowKey(inViewport: screen), "3")
    }

    func testAllowRefusesAScreenWithNoPlainYes() throws {
        XCTAssertNil(driver.allowKey(inViewport: try GrokScreenTests.screen("question.synthetic")))
        XCTAssertNil(driver.allowKey(inViewport: try GrokScreenTests.screen("tui-idle.synthetic")))
    }

    func testAnOptionIsPickedByItsPrintedKeyOnlyWhenItsLabelMatches() throws {
        let screen = try GrokScreenTests.screen("question.synthetic")
        XCTAssertEqual(driver.optionKey(1, label: "Blue", inViewport: screen), "2")
        XCTAssertNil(driver.optionKey(1, label: "Red", inViewport: screen))
        XCTAssertNil(driver.optionKey(2, label: "Type your answer here", inViewport: screen),
                     "the free-text row is not an option")
    }

    func testDenyIsCtrlCBecauseEscapeOnlyParksFocus() {
        let spy = SpyInjector()
        driver.deny(spy)
        XCTAssertEqual(spy.events, [.control("c")])
    }

    func testASelectListIsSeenOnlyWhenACardIsUp() throws {
        XCTAssertTrue(driver.hasSelectList(inViewport: try GrokScreenTests.screen("permission-write.synthetic")))
        XCTAssertFalse(driver.hasSelectList(inViewport: try GrokScreenTests.screen("tui-draft.synthetic")))
    }
}
