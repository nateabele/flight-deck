import IntakeKit
import XCTest
@testable import FlightDeck

/// OpenCode's screen grammar — the composer, the dialog veto and the select-list check —
/// proved against `Fixtures/OpenCode/*.captured.txt` (see the provenance file there).
@MainActor
final class OpenCodeScreenTests: XCTestCase {
    /// Screens with a dialog covering the composer.
    private static let dialogs = ["permission-dialog", "question-dialog"]
    /// Screens whose composer is on screen and may be sent to. The slash-command menu sits
    /// ABOVE an intact composer, and delivery never types, so it is no veto case.
    private static let composers = ["idle-composer", "draft-composer", "busy-composer", "slash-menu"]
    /// Screens with no OpenCode at all: a shell before launch, and the terminal after the TUI
    /// exited (replayed with the alternate screen emulated — see the provenance file).
    private static let noTUI = ["shell-prompt", "after-exit"]

    func testTheCorpusSplitCoversEveryCapture() throws {
        let classified = Set(Self.dialogs + Self.composers + Self.noTUI)
        XCTAssertEqual(classified.count, Self.dialogs.count + Self.composers.count + Self.noTUI.count)
        let onDisk = try ClaudeDialogVetoTests.capturedNames(in: "OpenCode")
        XCTAssertEqual(onDisk.subtracting(classified).sorted(), [], "unclassified capture")
        XCTAssertEqual(classified.subtracting(onDisk).sorted(), [], "listed capture missing on disk")
    }

    func testEveryDialogVetoes() throws {
        for name in Self.dialogs {
            XCTAssertTrue(OpenCodeTextChannel.isKnownNonComposer(try OpenCodeFixtures.screen(name)), name)
            XCTAssertFalse(OpenCodeTextChannel.hasComposerBox(try OpenCodeFixtures.screen(name)), name)
        }
    }

    func testEveryComposerIsFoundAndNotVetoed() throws {
        for name in Self.composers {
            let screen = try OpenCodeFixtures.screen(name)
            XCTAssertTrue(OpenCodeTextChannel.hasComposerBox(screen), name)
            XCTAssertFalse(OpenCodeTextChannel.isKnownNonComposer(screen), name)
        }
    }

    /// A dead TUI leaves no composer behind — unlike claude, whose box outlives it.
    func testNoComposerWithoutATUI() throws {
        for name in Self.noTUI {
            let screen = try OpenCodeFixtures.screen(name)
            XCTAssertFalse(OpenCodeTextChannel.hasComposerBox(screen), name)
            XCTAssertFalse(OpenCodeTextChannel.isKnownNonComposer(screen), name)
        }
    }

    func testEmptinessReadsTheComposerRows() throws {
        let channel = OpenCodeTextChannel()
        let idle = SpyInjector(); idle.viewportOverride = try OpenCodeFixtures.screen("idle-composer")
        let draft = SpyInjector(); draft.viewportOverride = try OpenCodeFixtures.screen("draft-composer")
        XCTAssertTrue(channel.isComposerEmpty(idle))
        XCTAssertFalse(channel.isComposerEmpty(draft))
    }

    func testTheDriverSeesSelectListsAndCannotCountRows() throws {
        let driver = OpenCodeDialogDriver()
        for name in Self.dialogs {
            let screen = try OpenCodeFixtures.screen(name)
            XCTAssertTrue(driver.hasSelectList(inViewport: screen), name)
            XCTAssertNil(driver.focusedRow(inViewport: screen), "focus is colour-only on \(name)")
            XCTAssertFalse(driver.row(0, reads: "Yes", inViewport: screen))
        }
        for name in Self.composers + Self.noTUI {
            XCTAssertFalse(driver.hasSelectList(inViewport: try OpenCodeFixtures.screen(name)), name)
        }
        XCTAssertEqual(driver.allowRow, 0)
    }

    func testDenyIsOneEscape() {
        let spy = SpyInjector()
        OpenCodeDialogDriver().deny(spy)
        XCTAssertEqual(spy.events, [.escape])
    }
}
