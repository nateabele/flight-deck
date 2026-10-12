import FleetKit
import SafariServices
import SwiftUI

/// An in-app browser for the one page a prompt card sends a reader to — claude's OAuth sign-in
/// (`PromptCard`).
///
/// **`SFSafariViewController`, not a `WKWebView`, and not `openURL`.** It shares Safari's
/// cookies, so a reader already signed in to claude.ai sees an "Authorize" button rather than a
/// login form; the web view would start from nothing. And unlike `openURL` it keeps the reader
/// in the app: the page shows a code to copy, and the card — with the field it is pasted into —
/// is one swipe away rather than behind an app switch.
///
/// Created with the URL already vetted (`ClaudeSignInURL`): this view follows whatever it is
/// given and is not the place that decides.
struct SafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}

/// A page to show, `Identifiable` so a sheet can be driven off an optional.
struct SignInPage: Identifiable, Equatable {
    let url: URL
    var id: URL { url }

    /// The page for `link`, or nil when it is not a URL this build will open — the rule the Mac
    /// shipped it under (`ClaudeSignInURL`), run again here because this is the one place a
    /// phone follows a link on a Mac's say-so.
    init?(_ link: String) {
        guard let parsed = ClaudeSignInURL.parse(link) else { return nil }
        url = parsed.url
    }
}
