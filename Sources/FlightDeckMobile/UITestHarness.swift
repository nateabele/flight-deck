import SwiftUI

/// A test-only probe, reachable ONLY under a launch argument, that reproduces one question
/// in isolation: when a `Text(AttributedString)` carrying a `.link` run sits inside a whole-row
/// `NavigationLink(value:)`, does a tap on the URL open the link (Safari) or does the
/// `NavigationLink` swallow the tap and navigate?
///
/// This exists to settle the untested claim in `SessionTimelineScreen.entryRow`'s doc comment —
/// "a `NavigationLink` swallows the tap on any control inside it" — against the linkified
/// plain-kind rows introduced by `TimelineStyle.linkedPlainText`. It mirrors that exact
/// structure and nothing else: no fleet, no model, no data path, so the outcome is purely the
/// SwiftUI tap-precedence answer. See `FlightDeckMobileUITests`.
///
/// Gated behind `-UITestHarness <name>` so it can never appear in a shipping run: the app only
/// consults it when the argument is present, which XCUITest sets via `launchArguments`.
enum UITestHarness {
    /// The value passed as `-UITestHarness` for the link-in-NavigationLink probe.
    static let linkInNavLink = "linkInNavLink"

    /// The harness the current launch asks for, if any. `UserDefaults` surfaces a
    /// `-Key Value` launch argument pair as a string default, which is how XCUITest hands
    /// this in without the app parsing `CommandLine` itself.
    static var requested: String? {
        UserDefaults.standard.string(forKey: "UITestHarness")
    }

    /// The root view for a requested harness, or nil when none was asked for (the normal app).
    @ViewBuilder @MainActor
    static func view(for name: String) -> some View {
        switch name {
        case linkInNavLink:
            LinkInNavLinkHarness()
        default:
            // An unknown harness name is a test bug, not a state to render silently.
            Text("Unknown UITestHarness: \(name)")
        }
    }
}

/// A single row wrapped in `NavigationLink(value:)`, exactly as `entryRow` wraps a plain-kind
/// row, whose label is a `Text(AttributedString)` with a `.link` run over a bare URL. Tapping
/// the URL either follows the link (nothing navigates here) or fires the `NavigationLink` and
/// pushes the destination carrying the "probe-detail" identifier.
private struct LinkInNavLinkHarness: View {
    private static let url = URL(string: "https://example.com")!

    /// The whole visible label is the bare URL, styled exactly as `TimelineStyle.linkedPlainText`
    /// styles a detected run (`.link` + `.accentColor`). Making the URL the entire label means a
    /// tap anywhere on the row lands on the `.link` run — so the tap under test is unambiguously
    /// "on the link AND on the enclosing NavigationLink", which is the precedence question.
    private var linkedText: AttributedString {
        var attributed = AttributedString("https://example.com")
        attributed.link = Self.url
        attributed.foregroundColor = .accentColor
        return attributed
    }

    var body: some View {
        NavigationStack {
            List {
                NavigationLink(value: "probe") {
                    Text(linkedText)
                        .accessibilityIdentifier("probe-row")
                }
            }
            .navigationDestination(for: String.self) { _ in
                Text("Detail screen")
                    .accessibilityIdentifier("probe-detail")
            }
        }
    }
}
