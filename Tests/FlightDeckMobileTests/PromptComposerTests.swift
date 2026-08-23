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
    private func session(agent: String = "claude", activity: String? = "idle") -> WireSession {
        WireSession(id: UUID(), title: "t", agent: agent, activity: activity)
    }

    /// Refused on the phone as well as on the Mac, and the two are not redundant: the Mac's
    /// refusal is the guarantee, and this one is the difference between a disabled field with
    /// a sentence under it and a message someone typed, sent, and got an error for.
    func testACodexTabSaysWhyRatherThanOfferingAFieldThatWillFail() {
        XCTAssertEqual(
            PromptComposer.unavailable(for: session(agent: "codex")),
            "Flight Deck can only type into a Claude session from here."
        )
    }

    /// An agent this build has never heard of is refused too. `WireSession.agent` is a
    /// `String` precisely so a new agent does not take the snapshot down — and an unknown
    /// agent has no known input box either.
    func testAnUnknownAgentIsAlsoRefused() {
        XCTAssertNotNil(PromptComposer.unavailable(for: session(agent: "gemini")))
    }

    /// Two fixtures, because `nil` and `"shell"` are different values and a check handling
    /// only one of them would pass a single-fixture test.
    func testAShellTabAndAStatuslessTabAreBothUnavailable() {
        XCTAssertEqual(
            PromptComposer.unavailable(for: session(activity: "shell")),
            "There's no agent running in this tab right now."
        )
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
