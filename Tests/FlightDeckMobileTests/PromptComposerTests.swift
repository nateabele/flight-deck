import FleetKit
import XCTest
@testable import FlightDeckMobile

/// The composer's two decisions, which are the only parts of it a simulator test can reach:
/// whether this tab can take a message at all, and whether this draft can be sent.
///
/// Nothing here asserts anything SwiftUI renders — layout, the keyboard, whether the field
/// grows — which stays in `docs/MOBILE.md`'s checklist, per this suite's own rule.
@MainActor
final class PromptComposerTests: XCTestCase {
    private func session(
        agent: String = "claude", activity: String? = "idle", hasBackgroundWork: Bool = false
    ) -> WireSession {
        WireSession(
            id: UUID(), title: "t", agent: agent, activity: activity,
            hasBackgroundWork: hasBackgroundWork)
    }

    /// **Codex is typeable, by the same route as claude: text into the tab's pty.** This test
    /// used to assert the opposite — that a codex tab was refused with "Flight Deck can only
    /// type into a Claude session from here." — on the theory that `InputBar.read` might
    /// mistake codex's composer for a shell's. It could not: codex draws `›` (U+203A) and
    /// `InputBar` locked onto `❯`, so it matched nothing on a codex screen at all. See
    /// `CodexTextChannel` and `PromptComposer.unavailable`.
    func testACodexTabIsOfferedAField() {
        XCTAssertNil(PromptComposer.unavailable(for: session(agent: "codex")))
    }

    /// An agent this build has never heard of is refused too. `WireSession.agent` is a
    /// `String` precisely so a new agent does not take the snapshot down — and an unknown
    /// agent has no known input box either.
    func testAnUnknownAgentIsAlsoRefused() {
        XCTAssertNotNil(PromptComposer.unavailable(for: session(agent: "gemini")))
    }

    /// The phone's early refusal must agree with the Mac's late one. Both used to reject a live
    /// idle agent because `"shell"` was read as "a bare prompt".
    func testIdleWithBackgroundWorkIsSendable() {
        XCTAssertNil(PromptComposer.unavailable(
            for: session(activity: "idle", hasBackgroundWork: true)))
    }

    /// Still refused, and this is the only remaining reason: no agent process at all.
    func testNoAgentIsStillRefused() {
        XCTAssertEqual(
            PromptComposer.unavailable(for: session(activity: nil)),
            "There's no agent running in this tab right now."
        )
    }

    func testASessionTheFleetNoLongerListsSaysSo() {
        XCTAssertEqual(
            PromptComposer.unavailable(for: nil),
            "This session is no longer open on your Mac."
        )
    }

    /// The negative controls, and there are three because a composer that refused every
    /// non-idle state would silently stop working exactly when it is most wanted: mid-turn.
    func testAClaudeTabIsAvailableIdleBusyAndWaiting() {
        XCTAssertNil(PromptComposer.unavailable(for: session(activity: "idle")))
        XCTAssertNil(PromptComposer.unavailable(for: session(activity: "busy")))
        XCTAssertNil(PromptComposer.unavailable(for: session(activity: "waiting")))
    }

    func testSendIsRefusedForWhitespaceEvenOnAnAvailableTab() {
        XCTAssertFalse(PromptComposer.canSend(draft: "   \n ", unavailable: nil, isSending: false))
    }

    /// The same rule the Mac enforces, run here so the round trip is never spent teaching
    /// someone something the field already knew.
    func testSendIsRefusedForTextTheMacWouldRefuse() {
        XCTAssertFalse(
            PromptComposer.canSend(draft: "go\u{1b}[201~ahead", unavailable: nil, isSending: false)
        )
    }

    func testSendIsRefusedWhileAnEarlierMessageIsStillInFlight() {
        XCTAssertFalse(PromptComposer.canSend(draft: "ship it", unavailable: nil, isSending: true))
    }

    func testSendIsRefusedOnAnUnavailableTabEvenWithGoodText() {
        XCTAssertFalse(
            PromptComposer.canSend(draft: "ship it", unavailable: "nope", isSending: false)
        )
    }

    func testSendIsOfferedForOrdinaryTextOnAnAvailableIdleTab() {
        XCTAssertTrue(PromptComposer.canSend(draft: "ship it", unavailable: nil, isSending: false))
    }
}
