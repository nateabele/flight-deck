import Foundation
import IntakeKit

/// Where a hand-off agent finds the old agent's transcript, and how to read it (L3-U §5).
///
/// Each pointer is the file Flight Deck itself already tails for that tab, never a re-derived
/// path: claude's follows `transcriptDirectory` into worktrees, codex's is the rollout codex
/// reported. All of them are on this Mac, so the new agent can read them whatever account it
/// runs on.
enum TranscriptPointers {
    static let claudeFormat = "Claude Code transcript, JSONL: one JSON record per line"
    static let claudeHowToRead = "Read the last 200 lines first (`tail -n 200`). Records with \"type\":\"user\" and \"type\":\"assistant\" hold the conversation; tool_use and tool_result blocks inside message.content show what was run and what it returned."
    static let codexFormat = "Codex rollout, JSONL: one {timestamp, type, payload} record per line"
    static let codexHowToRead = "Read the last 300 lines first (`tail -n 300`). response_item records hold the messages and tool calls; event_msg records hold tool output."
    static let openCodeFormat = "OpenCode session export, JSON"
    static let openCodeHowToRead = "Run the command and read its output; the last messages show where the work stopped."

    static func claude(session: Session, projectsRoot: URL,
                       exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> TranscriptPointer? {
        let url = ClaudeSession.transcriptURL(sessionID: session.pinnedConversationID,
                                              workingDirectory: session.transcriptDirectory,
                                              projectsRoot: projectsRoot)
        guard exists(url.path) else { return nil }
        return TranscriptPointer(locator: .path(url.path), format: claudeFormat, howToRead: claudeHowToRead)
    }

    static func codex(session: Session,
                      exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> TranscriptPointer? {
        guard let path = session.transcriptPath, exists(path) else { return nil }
        return TranscriptPointer(locator: .path(path), format: codexFormat, howToRead: codexHowToRead)
    }

    static let geminiFormat = "Antigravity CLI (agy) transcript, JSONL: one step per line"
    static let geminiHowToRead = "Read the last 200 lines first (`tail -n 200`). USER_INPUT records hold the user's request inside <USER_REQUEST>; PLANNER_RESPONSE records hold the model's reply and tool_calls; GENERIC records are tool results, in order after the call."

    /// agy names the transcript after the conversation, under its own root, so the path is the
    /// pin's; it exists once the tab's agy has recorded a step.
    static func gemini(session: Session, paths: GeminiPaths = .default,
                       exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> TranscriptPointer? {
        let url = paths.transcript(session.pinnedConversationID)
        guard exists(url.path) else { return nil }
        return TranscriptPointer(locator: .path(url.path), format: geminiFormat, howToRead: geminiHowToRead)
    }

    /// For the OpenCode adapter when it merges: `opencode export` against local storage, or the
    /// server's messages endpoint when the account runs its own server. Probe both against the
    /// OpenCode branch before relying on them.
    static func openCode(sessionID: String, serverURL: URL?) -> TranscriptPointer {
        let command = serverURL.map { "curl -s \($0.absoluteString)/session/\(sessionID)/message" } ?? "opencode export \(sessionID)"
        return TranscriptPointer(locator: .command(command), format: openCodeFormat, howToRead: openCodeHowToRead)
    }
}
