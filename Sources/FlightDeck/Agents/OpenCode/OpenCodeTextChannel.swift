import Foundation
import IntakeKit
import OSLog

/// **OpenCode's text channel: read the screen like the other two, deliver like neither.**
///
/// The two screen predicates are a grammar for OpenCode's TUI, derived from the captures in
/// `Fixtures/OpenCode` (see the provenance file there). Delivery is NOT keystrokes: `submit`
/// sends the text to the tab's session over OpenCode's own API (`prompt_async`), which reaches
/// only that session, is queued if the session is mid-turn, and never touches the composer —
/// so the whole draft dance claude and codex need (kill, compare, yank back) does not exist
/// here. A person halfway through typing keeps their draft; live-probed, `my unsent draft`
/// survived a phone-style prompt, a question and a busy turn underneath it.
///
/// **The screen predicates still matter, for the gate rather than the delivery.**
/// `SessionStore.injectionGate` asks them before any channel is used, and the veto keeps a
/// message from being queued behind a dialog the user has not answered yet — the same
/// ordering the other two agents give, so a phone's message and its permission card cannot
/// race each other.
struct OpenCodeTextChannel: AgentTextChannel {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "dev.flightdeck.FlightDeck",
        category: "opencode"
    )

    /// The two dialogs that cover the composer, each by text only it draws: a permission
    /// request's header, and the footer of the select lists (question: `↑↓ select  enter
    /// submit  esc dismiss`; permission: `⇆ select  enter confirm`). Footers rather than option
    /// rows because an option row is free text the MODEL wrote — a question whose first option
    /// reads like a composer must not unlock injection.
    static let dialogTokens = ["△ Permission required", "↑↓ select", "⇆ select"]

    func isComposerEmpty(_ injector: TextInjecting) -> Bool {
        guard let viewport = injector.readViewport(),
              let rows = Self.composerRows(viewport)
        else { return false }
        return rows.allSatisfy { row in
            let text = Self.gutterContent(row)
            return text.isEmpty || text.hasPrefix("Ask anything")
        }
    }

    /// See `AgentTextChannel.draft`. The gutter rows' text, with OpenCode's `Ask anything…`
    /// placeholder read as empty — the same rule `isComposerEmpty` uses.
    func draft(_ injector: TextInjecting) -> String? {
        guard let viewport = injector.readViewport(), let rows = Self.composerRows(viewport) else { return nil }
        let text = rows.map(Self.gutterContent).filter { !$0.isEmpty }.joined(separator: " ")
        return text.hasPrefix("Ask anything") ? "" : text
    }

    func hasComposerBox(_ injector: TextInjecting) -> Bool {
        guard let viewport = injector.readViewport() else { return false }
        return Self.hasComposerBox(viewport)
    }

    func isKnownNonComposer(_ injector: TextInjecting) -> Bool {
        guard let viewport = injector.readViewport() else { return false }
        return Self.isKnownNonComposer(viewport)
    }

    static func isKnownNonComposer(_ viewport: String) -> Bool {
        dialogTokens.contains { viewport.contains($0) }
    }

    /// The composer is a gutter (`┃`) block closed by a `╹▀▀…` rule, whose last gutter line is
    /// the agent/model line (`┃  Build · fake-model Fake`). Both halves are required: the rule
    /// alone is drawn by nothing else on an OpenCode screen, but requiring the ` · ` line above
    /// it is what keeps a stray `▀` run in someone's output from counting.
    ///
    /// **A dead TUI leaves no composer behind, and that is measured.** OpenCode draws on the
    /// alternate screen (`ESC[?1049h` … `ESC[?1049l`, read out of the captured byte stream), so
    /// exiting returns the terminal to the shell's own screen — `after-exit.captured.txt` holds
    /// the logo, `Continue  opencode -s ses_…` and a prompt, and no rule. Claude's composer
    /// outlives claude on screen; OpenCode's does not.
    static func hasComposerBox(_ viewport: String) -> Bool {
        composerRows(viewport) != nil
    }

    /// The input rows of the composer — the gutter lines between the block's top and its
    /// agent/model line — or nil when there is no composer on screen.
    ///
    /// Each row is CLIPPED to the composer's own columns, taken from the extent of its `╹▀▀…`
    /// rule. On a wide terminal OpenCode draws its session sidebar (title, context, cost, the
    /// working directory) on the same rows, to the right of the box, and reading whole lines
    /// would mistake that sidebar for text in the composer.
    static func composerRows(_ viewport: String) -> [String]? {
        let lines = viewport.split(separator: "\n", omittingEmptySubsequences: false).map(Array.init)
        guard let ruleIndex = lines.lastIndex(where: { String($0).trimmingCharacters(in: .whitespaces).hasPrefix("╹▀") }),
              ruleIndex > 0,
              let start = lines[ruleIndex].firstIndex(of: "╹")
        else { return nil }
        var end = start + 1
        while end < lines[ruleIndex].count, lines[ruleIndex][end] == "▀" { end += 1 }
        func clipped(_ line: [Character]) -> String {
            guard start < line.count else { return "" }
            return String(line[start..<min(end, line.count)])
        }
        let modelLine = clipped(lines[ruleIndex - 1])
        guard modelLine.contains("┃"), gutterContent(modelLine).contains(" · ") else { return nil }
        var rows: [String] = []
        var index = ruleIndex - 2
        while index >= 0 {
            let row = clipped(lines[index])
            guard row.trimmingCharacters(in: .whitespaces).hasPrefix("┃") else { break }
            rows.insert(row, at: 0)
            index -= 1
        }
        return rows
    }

    private static func gutterContent(_ line: String) -> String {
        guard let bar = line.firstIndex(of: "┃") else { return "" }
        return line[line.index(after: bar)...].trimmingCharacters(in: .whitespaces)
    }

    /// Sends `text` to the tab's own session. Refuses — returns false having sent nothing —
    /// when the injector carries no address: an unaddressed submit has no session to name,
    /// and guessing one is how a message lands in somebody else's conversation.
    func submit(
        _ text: String,
        into injector: TextInjecting,
        settle: @escaping (@escaping () -> Void) -> Void,
        stillWanted: @escaping @MainActor () -> Bool,
        onFinished: @escaping @MainActor (Bool) -> Void
    ) -> Bool {
        guard let target = (injector as? TargetedInjector)?.target,
              let adapter = target.adapter as? OpenCodeAdapter,
              let session = OpenCodeIdentity.sessionID(fromTranscript: target.location.binding.transcriptURL)
        else { return false }
        let directory = target.location.workingDirectory
        // One settle, so a replacement or cancellation that arrives while the caller is still
        // unwinding is seen before anything is sent — the same window `stillWanted` covers for
        // the keystroke channels.
        settle {
            guard stillWanted() else { return onFinished(false) }
            Task { @MainActor in
                do {
                    try await adapter.client().prompt(session, text: text, directory: directory)
                    onFinished(true)
                } catch {
                    Self.logger.error(
                        "prompt_async failed for \(session, privacy: .public): \(String(describing: error), privacy: .public)"
                    )
                    onFinished(false)
                }
            }
        }
        return true
    }
}
