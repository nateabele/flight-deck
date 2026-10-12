import FleetKit
import Foundation

/// Names the dialog a claude session is blocked on **from the terminal screen alone**, for the
/// dialogs claude never writes to its transcript — see `ScreenPromptID` for why those exist and
/// how a phone is told.
///
/// Pure over a viewport string, so every rule here is testable against a capture
/// (`Fixtures/Claude/login-*.captured.txt`). Two shapes, tried in this order because they cannot
/// both be on one screen and the sign-in's is the more specific:
///
/// - **A sign-in** — the browser-did-not-open screen of claude's OAuth login.
/// - **A menu** — a numbered select list (`ChoiceDialog.menu`).
///
/// Anything else is `nil`, which is "Waiting for you", unchanged from before this existed.
/// **Both fail toward nothing**: a screen this cannot read produces no card, never a guess.
enum ScreenPromptReader {
    /// The line claude draws under the URL, asking for the code the redirect page displays.
    /// Matched as a substring of the trimmed line rather than exactly: the glyph after it
    /// (`>`) is the prompt cursor and the text before it has been indented by every capture.
    static let pasteCodeMarker = "Paste code here if prompted"

    /// What a menu with no line above it asks. A card needs *a* question; this is honest about
    /// not knowing what it is rather than inventing one.
    static let unnamedMenuQuestion = "Claude is waiting for you to choose"

    static func read(inViewport viewport: String) -> OpenPrompt? {
        signIn(inViewport: viewport) ?? menu(inViewport: viewport)
    }

    // MARK: Menu

    static func menu(inViewport viewport: String) -> OpenPrompt? {
        guard let menu = ChoiceDialog.menu(
            inViewport: viewport, marker: ChoiceDialog.claudeMarker
        ) else { return nil }
        let question = PromptQuestion(
            question: menu.prompt ?? unnamedMenuQuestion,
            options: menu.rows.map { PromptQuestion.Option(label: $0.label, detail: $0.detail) }
        )
        return .question(
            callID: ScreenPromptID.menu(prompt: menu.prompt, labels: menu.rows.map(\.label)),
            [question]
        )
    }

    // MARK: Sign-in

    /// The OAuth sign-in screen: the paste-code prompt **and** an authorize URL above it that a
    /// phone can complete (`ClaudeSignInURL`).
    ///
    /// **The URL is hard-wrapped at the terminal's width with no space at the break**
    /// (`login-paste-code.captured.txt` wraps it across four 140-column lines), so it is
    /// rejoined from the line that starts it through the unbroken run of non-blank,
    /// whitespace-free lines after it. Whitespace-free is what stops the join at the first line
    /// of prose: a continuation never contains a space, and the paste-code prompt always does.
    ///
    /// **A screen with the prompt and no usable URL is not a sign-in card.** That covers a
    /// localhost redirect and a URL whose last line scrolled off — both fail `ClaudeSignInURL`,
    /// and the answer is the same "Waiting for you" as before rather than a button that opens a
    /// dead end.
    static func signIn(inViewport viewport: String) -> OpenPrompt? {
        let lines = viewport.components(separatedBy: "\n")
        guard let prompt = lines.lastIndex(where: { $0.contains(pasteCodeMarker) }),
              let start = lines[..<prompt].lastIndex(where: {
                  let text = $0.trimmingCharacters(in: .whitespaces)
                  return text.hasPrefix("https://") && text.contains("/oauth/authorize")
              })
        else { return nil }

        var joined = lines[start].trimmingCharacters(in: .whitespaces)
        var next = start + 1
        while next < prompt {
            let piece = lines[next].trimmingCharacters(in: .whitespaces)
            guard !piece.isEmpty, !piece.contains(where: \.isWhitespace) else { break }
            joined += piece
            next += 1
        }
        guard let parsed = ClaudeSignInURL.parse(joined) else { return nil }
        return .signIn(callID: ScreenPromptID.signIn(state: parsed.state),
                       url: parsed.url.absoluteString)
    }
}
