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
        signIn(inViewport: viewport) ?? workspaceTrust(inViewport: viewport)?.prompt
            ?? menu(inViewport: viewport)
    }

    // MARK: Folder trust

    /// The header claude draws above the folder it is asking about.
    static let accessingWorkspaceMarker = "Accessing workspace:"
    /// The trust screen's accepting row, exactly as claude labels it.
    static let trustFolderLabel = "Yes, I trust this folder"
    /// The trust screen's two rows. Matched by these exact words because the screen gives
    /// nothing else to go on: since 2.1.310 they carry no numbers.
    static let trustRowLabels: Set<String> = [trustFolderLabel, "No, exit"]

    /// claude's folder-trust screen, read.
    struct WorkspaceTrust {
        /// The folder claude is asking about.
        var folder: String
        /// The rows' labels, top to bottom, as the screen orders them.
        var rows: [String]
        /// Which of `rows` the cursor is on.
        var focused: Int
        var prompt: OpenPrompt
    }

    /// claude's folder-trust screen: its rows, its cursor, and the folder it asks about.
    ///
    /// **Shown before claude has booted far enough to write a status file or fire a hook**, so
    /// a tab on it has no activity at all and the generic `menu` reading is never asked — see
    /// `SessionStore.trustScreen(for:)`.
    ///
    /// **Its own reader, not `ChoiceDialog.menu`, because claude changed the screen under it.**
    /// 2.1.241 drew `❯ 1. Yes, I trust this folder` / `2. No, exit`; 2.1.310 draws the rows
    /// unnumbered and the other way up — `❯ No, exit` first and focused, `Yes, I trust this
    /// folder` under it (`workspace-trust-310.captured.txt`). `ChoiceDialog` refuses an
    /// unnumbered list by design, so it reads nothing on a current claude. This reader accepts
    /// either, and makes up for having no numbers by asking more of everything else:
    ///
    /// - the `Accessing workspace:` header, with the rows below it;
    /// - exactly the two known labels, once each, on adjacent lines;
    /// - exactly one of them carrying the cursor;
    /// - no `❯` line below them — a composer under the rows would make them scrollback.
    ///
    /// The folder is every non-blank line under the header up to the first blank one, joined
    /// without spaces: a long path wraps at the terminal's width, with no space at the break.
    static func workspaceTrust(inViewport viewport: String) -> WorkspaceTrust? {
        let lines = viewport.components(separatedBy: "\n")
        guard let header = lines.lastIndex(where: {
            $0.trimmingCharacters(in: .whitespaces) == accessingWorkspaceMarker
        }) else { return nil }

        var folder = ""
        var next = header + 1
        while next < lines.count, lines[next].trimmingCharacters(in: .whitespaces).isEmpty { next += 1 }
        while next < lines.count {
            let piece = lines[next].trimmingCharacters(in: .whitespaces)
            guard !piece.isEmpty else { break }
            folder += piece
            next += 1
        }
        guard folder.hasPrefix("/") else { return nil }

        var rows: [(label: String, marked: Bool, line: Int)] = []
        for index in next..<lines.count {
            if let row = trustRow(lines[index]) { rows.append((row.label, row.marked, index)) }
        }
        guard rows.count == 2, Set(rows.map(\.label)) == trustRowLabels,
              rows[1].line == rows[0].line + 1,
              rows.filter(\.marked).count == 1,
              let focused = rows.firstIndex(where: \.marked),
              !lines[(rows[1].line + 1)...].contains(where: {
                  $0.trimmingCharacters(in: .whitespaces).first == ChoiceDialog.claudeMarker
              })
        else { return nil }

        let labels = rows.map(\.label)
        let text = "Trust \(folder)? Claude will be able to read, edit, and execute files here."
        let question = PromptQuestion(
            question: text, options: labels.map { PromptQuestion.Option(label: $0) }
        )
        return WorkspaceTrust(
            folder: folder, rows: labels, focused: focused,
            prompt: .question(callID: ScreenPromptID.menu(prompt: text, labels: labels), [question])
        )
    }

    /// One trust-screen row: an optional `❯`, an optional `N.`, then one of the two labels.
    private static func trustRow(_ line: String) -> (label: String, marked: Bool)? {
        var rest = Substring(line).drop(while: \.isWhitespace)
        let marked = rest.first == ChoiceDialog.claudeMarker
        if marked { rest = rest.dropFirst().drop(while: \.isWhitespace) }
        let digits = rest.prefix(while: \.isNumber)
        if !digits.isEmpty, rest.dropFirst(digits.count).first == "." {
            rest = rest.dropFirst(digits.count + 1).drop(while: \.isWhitespace)
        }
        let label = rest.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return trustRowLabels.contains(label) ? (label, marked) : nil
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
