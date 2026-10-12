import Foundation

/// Identity, and the one URL rule, for a dialog the Mac read off the terminal **screen** rather
/// than out of the transcript.
///
/// **Why this exists at all.** `OpenPrompt.find` only names what claude writes to its transcript:
/// an `AskUserQuestion`, a permission prompt. Claude's own TUI menus (`/login`, `/model`, a
/// resume picker, "Teach auto mode?") never reach it, so a session blocked on one read "Waiting
/// for you" with nothing to tap. The Mac can see those menus — it holds the screen — and ships
/// what it read through the same channel gemini's agy uses (`WireSession.openPrompt`), under a
/// call id that names the *screen*. This type is that id, and it lives in `FleetKit` so the phone
/// can tell a screen-derived dialog from a transcript one without a second copy of the prefixes.
///
/// **A change of menu must be a wire change**, which is `OpenPromptIdentity`'s whole premise: the
/// id is derived from the menu's own words, so a menu replaced by another while the session stays
/// `waiting` moves `openPromptCall` and a phone drops the old card. The hash is FNV-1a over UTF-8,
/// written out here rather than taken from `Hasher`/`hashValue`, which are randomly seeded per
/// process — an id that differed between two launches of the Mac would look like a new dialog on
/// every restart and would be a different string on the phone that computed its own.
public enum ScreenPromptID {
    /// A numbered select list read off the screen.
    public static let menuPrefix = "screen:"
    /// claude's OAuth sign-in, awaiting the code its redirect page shows.
    public static let signInPrefix = "signin:"

    public static func isMenu(_ callID: String) -> Bool { callID.hasPrefix(menuPrefix) }
    public static func isSignIn(_ callID: String) -> Bool { callID.hasPrefix(signInPrefix) }
    /// Either shape. What the Mac routes to its screen path rather than to a transcript call.
    public static func isScreenDerived(_ callID: String) -> Bool {
        isMenu(callID) || isSignIn(callID)
    }

    /// The id of a menu: its prompt line and its rows' labels, in order.
    ///
    /// Nothing about the cursor is in it — the focused row moves while the dialog is the same
    /// dialog, and an id that moved with it would retire the phone's card on every arrow key
    /// someone pressed at the keyboard. Fields are separated by NUL so `["ab","c"]` and
    /// `["a","bc"]` are different menus.
    public static func menu(prompt: String?, labels: [String]) -> String {
        let fields = [prompt ?? ""] + labels
        return menuPrefix + fnv1a64Hex(fields.joined(separator: "\u{0}"))
    }

    /// The id of a sign-in: derived from the OAuth `state`, which is unique per login attempt, so
    /// a second `/login` is a different dialog and a retry of the same one is the same.
    ///
    /// **A digest of the state, never the state.** The id travels in every status frame and is
    /// written to the prompt log; the state is the attempt's CSRF secret and has no business in
    /// either.
    public static func signIn(state: String) -> String {
        signInPrefix + fnv1a64Hex(state)
    }

    static func fnv1a64Hex(_ text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        let hex = String(hash, radix: 16)
        return String(repeating: "0", count: 16 - hex.count) + hex
    }
}

/// The authorize URL claude prints when it could not open a browser, and the rule for trusting
/// one.
///
/// **Run on both ends over the same string.** The Mac refuses to ship a URL that fails it, and the
/// phone refuses to open one that fails it — the second is not redundant, because a Mac is not
/// the only thing that can put a string in a card's hands and an in-app browser is the one place a
/// phone follows a link without being asked twice.
///
/// What it accepts, and why each condition is there:
///
/// - **`https` on `claude.com` exactly, path ending `/oauth/authorize`.** The shape captured from
///   claude 2.1.296 (`Fixtures/Claude/login-paste-code.captured.txt`). Not `hasSuffix(".claude.com")`:
///   a rule that admitted subdomains would admit anything somebody can register under one, and
///   this build has seen exactly one host.
/// - **A `redirect_uri` that is not loopback.** claude opens *two* URLs for one attempt: the
///   browser's redirects to `http://localhost:<port>/callback`, which is a dead end on a phone —
///   the phone's `localhost` is the phone — and the on-screen one, which redirects to
///   `platform.claude.com`'s code page, where a person copies the code to paste back. Only the
///   second can be completed away from the Mac, and a card offering the first would sign nobody
///   in.
/// - **A `state`.** It is the identity (`ScreenPromptID.signIn`). A URL cut off before it — the
///   wrap's last line scrolled off the viewport — is a URL that cannot be named, and a prompt
///   that cannot be named is not shipped.
public enum ClaudeSignInURL {
    public struct Parsed: Equatable, Sendable {
        public let url: URL
        public let state: String
    }

    public static func parse(_ text: String) -> Parsed? {
        guard let components = URLComponents(string: text),
              components.scheme == "https",
              components.host == "claude.com",
              components.path.hasSuffix("/oauth/authorize"),
              let items = components.queryItems,
              let state = items.first(where: { $0.name == "state" })?.value, !state.isEmpty,
              let redirect = items.first(where: { $0.name == "redirect_uri" })?.value,
              isRemote(redirect),
              let url = components.url
        else { return nil }
        return Parsed(url: url, state: state)
    }

    /// Whether the redirect lands somewhere a phone can reach: `https`, and not a loopback or
    /// unspecified host. Anything that does not parse is refused rather than trusted.
    static func isRemote(_ redirect: String) -> Bool {
        guard let parts = URLComponents(string: redirect), parts.scheme == "https",
              let host = parts.host?.lowercased(), !host.isEmpty
        else { return false }
        let local: Set<String> = ["localhost", "127.0.0.1", "::1", "0.0.0.0", "[::1]"]
        return !local.contains(host) && !host.hasSuffix(".localhost")
    }
}
