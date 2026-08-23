import Foundation

/// Text a client asked the Mac to type into a live agent, checked before anyone types it.
///
/// **This is the guard the existing commands do not need.** `markRead` and `markUnread` name
/// a tab and carry no payload; a prompt carries a string that ends up in
/// `TextInjecting.sendText`, which is a *paste* into a pty running a full-screen TUI. Ghostty
/// wraps a paste in bracketed-paste markers — `ESC [ 200~ … ESC [ 201~`, which is why
/// `sendReturn()` goes through `ghostty_surface_key` instead — so a payload containing `ESC`
/// can close the bracket early and have everything after it read as raw terminal input rather
/// than as content: keystrokes, not text. `vendor/ghostty` in this checkout holds build
/// artifacts and not sources, so whether libghostty strips that sequence cannot be checked
/// here. It is refused before it reaches the pty rather than assumed harmless one layer down.
///
/// In `FleetKit` so the phone can disable its Send button on exactly the rule the Mac
/// enforces. **The phone running it is a courtesy; the Mac running it is the guarantee** —
/// `SessionStore.submitPrompt` re-checks every prompt regardless of what a client claims to
/// have checked, because a client is not trusted to have checked anything.
public struct PromptText: Equatable, Hashable, Sendable {
    /// Why a string is not sendable text. Each `rawValue` is the wire spelling carried in
    /// `err`'s `code` field, stated as a table rather than derived from the case name, for
    /// the same reason `TimelineAnchor.name` is: a case rename must not silently become a
    /// protocol break.
    public enum Rejection: String, Equatable, Sendable {
        /// Nothing but whitespace. Submitting it would press Return on an empty bar.
        case empty = "prompt_empty"
        /// Longer than `maxCharacters`.
        case tooLong = "prompt_too_long"
        /// Carries a C0 control or DEL. See this type's own comment.
        case controlCharacters = "prompt_control_characters"
    }

    /// Well under `TimelineLimits.maxItemBytes` (65,536), and that relationship is the
    /// reason for the number rather than a coincidence: the phone confirms a send by finding
    /// its own text verbatim in a transcript page, and a body at or over that cap comes back
    /// cut with `Body.truncatedBytes` set. A prompt long enough to be truncated is a prompt
    /// whose confirmation could never arrive, so it would sit in the outbox forever.
    public static let maxCharacters = 8_000

    /// Exactly what gets typed.
    public let value: String

    public init?(_ raw: String) {
        guard Self.rejection(for: raw) == nil else { return nil }
        self.value = Self.normalized(raw)
    }

    /// The reason, or `nil` when the string is sendable.
    ///
    /// Separate from `init?` because both ends need the reason and not just the verdict: the
    /// Mac has to answer *which* refusal on the wire, and the phone has to say which in copy.
    public static func rejection(for raw: String) -> Rejection? {
        let text = normalized(raw)
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .empty }
        if text.count > maxCharacters { return .tooLong }
        for scalar in text.unicodeScalars {
            // Tab and newline are ordinary content inside a bracketed paste and are the two
            // controls a person legitimately pastes — a snippet of indented code has both.
            // Everything else in C0, and DEL, is not text and has no business in a message.
            if scalar == "\n" || scalar == "\t" { continue }
            if scalar.value < 0x20 || scalar.value == 0x7F { return .controlCharacters }
        }
        return nil
    }

    /// Trailing newlines only, and never `\r`: `inject` sends the text and then Return as a
    /// separate key event, so a trailing newline inserts a blank line into the input box
    /// rather than submitting anything. A `\r` survives this and is then refused above,
    /// which is the right answer — a phone has no business sending CRLF to a pty.
    private static func normalized(_ raw: String) -> String {
        var text = raw
        while text.hasSuffix("\n") { text.removeLast() }
        return text
    }
}
