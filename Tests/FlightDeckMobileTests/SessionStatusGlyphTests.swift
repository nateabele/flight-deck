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

    /// Must equal `SessionStatus.tooltip(unread:backgroundWork:)` on macOS, character for
    /// character. `SessionStatusTests.testTooltipComposesBackgroundWork` is the other end.
    func testLabelComposesBackgroundWork() {
        XCTAssertEqual(
            SessionStatusGlyph.label(for: session(activity: "idle", hasBackgroundWork: true)),
            "Idle — background command running"
        )
        XCTAssertEqual(
            SessionStatusGlyph.label(for: session(activity: "busy", hasBackgroundWork: true)),
            "Working — background command running"
        )
        XCTAssertEqual(
            SessionStatusGlyph.label(for: session(activity: "idle")),
            "Idle"
        )
        // The two compositions above only ever exercised the plain forms of `baseLabel`; these
        // pin the clause against the unread override and against a real subagent count too,
        // matching `SessionStatusTests.testTooltipComposesBackgroundWork` on macOS.
        XCTAssertEqual(
            SessionStatusGlyph.label(
                for: session(activity: "idle", isUnread: true, hasBackgroundWork: true)
            ),
            "Finished — not yet viewed — background command running"
        )
        XCTAssertEqual(
            SessionStatusGlyph.label(
                for: session(activity: "busy", subagentCount: 2, hasBackgroundWork: true)
            ),
            "Working — 2 subagents — background command running"
        )
    }

    /// `nil` still means no accessibility element at all — a dead tab must not be a VoiceOver
    /// stop, and a background flag cannot resurrect one.
    func testNoAgentStillHasNoLabel() {
        XCTAssertNil(SessionStatusGlyph.label(for: session(activity: nil, hasBackgroundWork: true)))
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

    /// The label is the Mac's, from the same function — not a re-pinned literal. That is the
    /// whole reason `SessionAPIError` lives in FleetKit rather than being restated per platform.
    func testAPIErrorLabelMatchesTheSharedOne() {
        let error = SessionAPIError(status: 529, kind: "overloaded", isTransient: true)
        XCTAssertEqual(label(activity: "idle", apiError: error), error.label)
    }

    /// The case that matters most: the session died AND its process exited, so `activity` is
    /// nil. `baseLabel` returns nil for that and the glyph's nil branch renders no accessibility
    /// element at all — so the error branch has to come first, or the badge never appears in
    /// precisely the situation it exists for.
    func testAPIErrorLabelSurvivesANilActivity() {
        let error = SessionAPIError(status: 529, kind: "overloaded")
        XCTAssertEqual(label(activity: nil, apiError: error), error.label)
    }

    /// The error outranks unread, matching the Mac's precedence in `SessionStatusIcon` exactly.
    func testAPIErrorOutranksUnread() {
        let error = SessionAPIError(status: 500, kind: "server_error")
        XCTAssertEqual(label(activity: "idle", isUnread: true, apiError: error), error.label)
    }

    private func label(
        activity: String?, waitingFor: String? = nil,
        subagentCount: Int = 0, isUnread: Bool = false,
        apiError: SessionAPIError? = nil
    ) -> String? {
        SessionStatusGlyph.label(for: session(
            activity: activity, waitingFor: waitingFor,
            subagentCount: subagentCount, isUnread: isUnread,
            apiError: apiError
        ))
    }

    private func session(
        activity: String?, waitingFor: String? = nil,
        subagentCount: Int = 0, isUnread: Bool = false,
        hasBackgroundWork: Bool = false, apiError: SessionAPIError? = nil
    ) -> WireSession {
        WireSession(
            id: UUID(), title: "flight-deck", agent: "claude",
            activity: activity, waitingFor: waitingFor,
            subagentCount: subagentCount, isUnread: isUnread,
            hasBackgroundWork: hasBackgroundWork, apiError: apiError
        )
    }
}
