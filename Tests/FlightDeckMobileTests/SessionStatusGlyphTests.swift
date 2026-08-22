import FleetKit
import XCTest
@testable import FlightDeckMobile

/// The phone's status vocabulary against the Mac's, string for string.
///
/// This is a cross-device invariant with no compiler behind it: `SessionStatus` lives in the
/// macOS app target, so nothing links both halves and nothing can assert them in one place.
/// What holds it together is that the same literals are pinned from both ends — here against
/// `SessionStatusGlyph.label(for:)`, and on macOS in `SessionStatusTests` and
/// `SessionReadPolicyTests` against `SessionStatus.tooltip`/`tooltip(unread:)`. Either side
/// being reworded alone fails its own suite, which is the point: the labels have drifted once
/// already, and a VoiceOver user hearing a different word than the Mac's tooltip for the
/// identical state is the same disagreement a mismatched glyph would be.
final class SessionStatusGlyphTests: XCTestCase {
    func testIdleMatchesTheMacsTooltip() {
        XCTAssertEqual(label(activity: "idle"), "Idle")
    }

    /// `SessionStatus.tooltip(unread:)`'s one override. Unread is drawn with colour alone, so
    /// this string is the whole of what carries it for VoiceOver.
    func testAnUnreadIdleSessionReadsAsFinishedNotAsIdle() {
        XCTAssertEqual(label(activity: "idle", isUnread: true), "Finished — not yet viewed")
    }

    /// Only `idle` takes the unread override on the Mac; a busy session that is also unread
    /// still reads as busy. Collapsing that here would announce finished work that is running.
    func testUnreadDoesNotOverrideAnyOtherActivity() {
        XCTAssertEqual(label(activity: "busy", isUnread: true), "Working")
        XCTAssertEqual(label(activity: "waiting", isUnread: true), "Waiting for you")
    }

    func testBusySubagentCountsAreSingularizedTheSameWay() {
        XCTAssertEqual(label(activity: "busy"), "Working")
        XCTAssertEqual(label(activity: "busy", subagentCount: 1), "Working — 1 subagent")
        XCTAssertEqual(label(activity: "busy", subagentCount: 3), "Working — 3 subagents")
    }

    func testWaitingCarriesTheReasonWhenTheAgentGaveOne() {
        XCTAssertEqual(
            label(activity: "waiting", waitingFor: "permission prompt"),
            "Waiting for you — permission prompt"
        )
        XCTAssertEqual(label(activity: "waiting"), "Waiting for you")
        XCTAssertEqual(label(activity: "waiting", waitingFor: ""), "Waiting for you")
    }

    func testShellMatchesTheMacsTooltip() {
        XCTAssertEqual(label(activity: "shell"), "Background command running")
    }

    /// `nil` is not `"idle"`. A tab with no agent process registered renders nothing and
    /// carries no accessibility element at all — labelling it would make VoiceOver stop on
    /// every dead row in the list, and calling it "Idle" would make every dead tab look alive.
    func testNoAgentProcessGetsNoLabelAtAll() {
        XCTAssertNil(SessionStatusGlyph.label(for: session(activity: nil)))
    }

    /// The Mac may be newer than the phone, which is why `WireSession.activity` is a `String`
    /// and not an enum. An unknown state still announces something.
    func testAnUnrecognizedActivityStillAnnouncesSomething() {
        XCTAssertEqual(label(activity: "compacting"), "Unrecognized status")
    }

    private func label(
        activity: String?, waitingFor: String? = nil,
        subagentCount: Int = 0, isUnread: Bool = false
    ) -> String? {
        SessionStatusGlyph.label(for: session(
            activity: activity, waitingFor: waitingFor,
            subagentCount: subagentCount, isUnread: isUnread
        ))
    }

    private func session(
        activity: String?, waitingFor: String? = nil,
        subagentCount: Int = 0, isUnread: Bool = false
    ) -> WireSession {
        WireSession(
            id: UUID(), title: "flight-deck", agent: "claude",
            activity: activity, waitingFor: waitingFor,
            subagentCount: subagentCount, isUnread: isUnread
        )
    }
}
