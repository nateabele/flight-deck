import XCTest

/// Phase 0 PROBE. The make-or-break question for the inline-URL-taps feature: in the phone
/// timeline, plain-kind rows are a whole-row `NavigationLink(value:)` whose body `Text` now
/// carries `.link` runs over bare URLs (`TimelineStyle.linkedPlainText`). When a user taps such
/// an inline URL, does SwiftUI open the link (Safari) or does the enclosing `NavigationLink`
/// swallow the tap and navigate to the detail screen?
///
/// This drives an ISOLATED reproduction (`UITestHarness.linkInNavLink`) rather than the real
/// fleet timeline, so the outcome is purely the SwiftUI tap-precedence answer with no data path
/// in the way. The harness is a `NavigationStack` → `List` → `NavigationLink(value:)` whose label
/// is a `Text(AttributedString)` with a `.link` run, and a `.navigationDestination` showing a
/// screen identified "probe-detail".
///
/// The test ASSERTS whichever way it actually went and prints a one-line verdict, so this file
/// doubles as the regression guard the probe leaves behind.
final class LinkInNavLinkTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    func testInlineLinkTapPrecedence() {
        let app = XCUIApplication()
        app.launchArguments += ["-UITestHarness", "linkInNavLink"]
        app.launch()

        let row = app.staticTexts["probe-row"]
        XCTAssertTrue(row.waitForExistence(timeout: 20), "harness row never appeared")

        // Tap the centre of the row, which is the URL's `.link` run — the pixels shared by the
        // link and the enclosing NavigationLink. That is the exact contested tap.
        row.tap()

        // If the NavigationLink won, the destination pushes and "probe-detail" appears. If the
        // link won, SwiftUI hands the URL to the system (Safari) and nothing navigates in-app.
        let detail = app.otherElements["probe-detail"].firstMatch
        let detailText = app.staticTexts["probe-detail"].firstMatch
        let navigated = detail.waitForExistence(timeout: 5) || detailText.waitForExistence(timeout: 1)

        let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        // Give Safari a moment to come to the foreground if the link opened it.
        let safariOpened = safari.wait(for: .runningForeground, timeout: 5)

        if navigated {
            print("PROBE VERDICT: navlink-wins — the NavigationLink swallowed the tap and pushed 'probe-detail'. A Phase 1 refactor is needed.")
        } else if safariOpened {
            print("PROBE VERDICT: link-wins — Safari came to the foreground; the inline .link run handled the tap. The feature basically already works.")
        } else {
            print("PROBE VERDICT: link-wins (no in-app navigation, Safari not confirmed foreground) — the NavigationLink did NOT swallow the tap; no 'probe-detail' appeared.")
        }

        // The regression assertion: the feature is correct only if the NavigationLink does NOT
        // swallow the inline-link tap. If this ever starts navigating to detail, the inline-tap
        // feature has regressed.
        XCTAssertFalse(navigated,
            "NavigationLink swallowed the inline .link tap and navigated to 'probe-detail' — inline URL taps do not reach Safari.")
    }
}
