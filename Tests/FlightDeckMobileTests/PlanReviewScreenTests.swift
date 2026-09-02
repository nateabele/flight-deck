import FleetKit
import XCTest
@testable import FlightDeckMobile

/// The screen's own pure logic — everything that decides text without drawing anything, in
/// the style `SessionTimelineScreenTests` already tests `pairedResult` and `follow`: no
/// simulator rendering, no `scripts/smoke.sh`, just the functions a body reads from.
final class PlanReviewScreenTests: XCTestCase {

    // MARK: The verdict-tier notice — see Self.limitedNotice's own comment

    func testTheAnnotateTierNeedsNoNotice() {
        XCTAssertNil(PlanReviewScreen.limitedNotice(tier: "annotate"))
    }

    /// Worded so a reader who cannot pin anything still knows the plan is readable and a
    /// verdict still lands.
    func testTheVerdictTierExplainsWhyNothingIsTappable() {
        XCTAssertEqual(
            PlanReviewScreen.limitedNotice(tier: "verdict"),
            "Inline comments need Plannotator running on your Mac. "
                + "You can still read the plan and send a verdict."
        )
    }

    /// Any tier this build has never heard of gets the same explanation as `verdict` — the
    /// guard is `tier != "annotate"`, not a fixed list of known limited tiers.
    func testAnUnknownTierAlsoGetsTheNotice() {
        XCTAssertNotNil(PlanReviewScreen.limitedNotice(tier: "something-future"))
    }

    // MARK: The resolved footer's headline — see Self.resolvedTitle's own comment

    func testTheApprovedHeadline() {
        XCTAssertEqual(
            PlanReviewScreen.resolvedTitle(approved: true), "You approved this plan."
        )
    }

    func testTheChangesRequestedHeadline() {
        XCTAssertEqual(
            PlanReviewScreen.resolvedTitle(approved: false), "You asked for changes."
        )
    }

    /// The fallback for a gate resolved before this screen's own buttons ever ran — should
    /// not happen given how the banner reaches this screen, but a sentence beats a blank
    /// footer if it ever does.
    func testTheFallbackHeadlineWhenThisScreenNeverSentTheVerdict() {
        XCTAssertEqual(
            PlanReviewScreen.resolvedTitle(approved: nil), "This plan has been resolved."
        )
    }
}
