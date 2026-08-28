import XCTest
@testable import FlightDeck

/// What claude's screen actually shows while a turn is running — and therefore what the
/// mid-turn injection gate can and cannot learn from it.
///
/// **Nothing here asserts a fix. These are the facts a fix has to be built on**, and they are
/// recorded because getting them wrong is what this file exists to prevent: the gate in
/// `ClaudeTextChannel.isComposerEmpty` asks whether the input box is empty before typing into a
/// running turn, and every prompt sent from a paired phone mid-turn is refused for the turn's
/// whole duration, requeued, refused again, and finally dropped when the fifteen-minute window
/// expires. Nothing about that presents as an error on either end.
///
/// Every screen below is a verbatim capture of a live claude 2.1.246 at 120×34, driven through
/// a pty and rendered by pyte — the same method and renderer as the dialog fixtures beside them.
/// See `Fixtures/Claude/dialogs.captured.provenance.json`.
@MainActor
final class MidTurnDraftTests: XCTestCase {

    private func screen(_ name: String) throws -> String {
        let url = try XCTUnwrap(
            Bundle(for: Self.self).url(
                forResource: "\(name).captured", withExtension: "txt", subdirectory: "Fixtures/Claude"
            ),
            "missing fixture \(name).captured.txt"
        )
        return try String(contentsOf: url, encoding: .utf8)
    }

    // MARK: At rest

    /// The state the gate was designed against, and the only one it reads correctly.
    func testAnIdleBoxIsOneEmptyRow() throws {
        let bar = try XCTUnwrap(InputBar.read(fromViewport: screen("idle-empty-box")))
        XCTAssertEqual(bar.rows.count, 1)
        XCTAssertEqual(bar.content, "")
    }

    // MARK: The moment after submitting, before output arrives

    /// **Claude leaves the message that started the turn sitting in its box.** So even in the
    /// one mid-turn state where the box IS on screen, it is not textually empty — and an
    /// emptiness test reads the running prompt as though the user had typed it.
    func testTheBoxHoldsTheRunningPromptJustAfterSubmitting() throws {
        let bar = try XCTUnwrap(InputBar.read(fromViewport: screen("busy-echo-only")))
        XCTAssertEqual(bar.rows.count, 1)
        XCTAssertTrue(bar.content.hasPrefix("Count from 1 to 40"), bar.content)
    }

    /// A draft typed during that window lands *beneath* the echo rather than replacing it, so
    /// in this state the two are distinguishable by row count.
    func testADraftTypedInThatWindowLandsOnASecondRow() throws {
        let bar = try XCTUnwrap(InputBar.read(fromViewport: screen("busy-draft-below-echo")))
        XCTAssertEqual(bar.rows.count, 2)
        XCTAssertTrue(bar.content.contains("a new draft typed mid-turn"), bar.content)
    }

    // MARK: Once output is actually streaming — the ordinary case

    /// **The finding that overturned two theories about this bug, in both directions.**
    ///
    /// The box does not vanish once output flows: it stays pinned at the bottom of the
    /// viewport, below the streaming text, and it is EMPTY. An earlier scrollback echo is still
    /// on screen above it — `InputBar.read` takes the last marker, which is what makes it read
    /// the live box rather than the echo.
    ///
    /// So the mid-turn gate is not what refuses a phone's prompt during a turn. It answers
    /// "the box is free" for all but the first second or two. Whatever holds those prompts is
    /// somewhere else in `SessionStore.inject`, and this test exists so the next person does
    /// not spend an afternoon proving the same thing again.
    func testTheBoxStaysOnScreenAndEmptyWhileOutputStreams() throws {
        for name in ["busy-streaming-no-box", "busy-streaming-no-marker"] {
            let bar = try XCTUnwrap(
                InputBar.read(fromViewport: try screen(name)),
                "\(name): the live box is still on screen"
            )
            XCTAssertEqual(bar.rows.count, 1, "\(name)")
            XCTAssertEqual(bar.content, "", "\(name): and it is empty")
        }
    }

    /// The one mid-turn window the gate really does refuse: between submitting and the first
    /// output, the box holds the echo. It is brief, and `flushPromptQueue` retries on every
    /// registry tick, so a prompt caught by it waits a tick rather than a turn.
    func testOnlyTheWindowBeforeOutputReadsAsBusy() throws {
        let echo = try XCTUnwrap(InputBar.read(fromViewport: screen("busy-echo-only")))
        XCTAssertFalse(echo.content.isEmpty, "refused, briefly")

        let streaming = try XCTUnwrap(InputBar.read(fromViewport: screen("busy-streaming-no-box")))
        XCTAssertTrue(streaming.content.isEmpty, "and free again once output starts")
    }
}
