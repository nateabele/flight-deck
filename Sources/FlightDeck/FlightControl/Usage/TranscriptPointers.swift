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
    static let grokFormat = "grok session updates, JSONL: one ACP session/update notification per line"
    static let grokHowToRead = "Read the last 200 lines first (`tail -n 200`). params.update.sessionUpdate names each record: user_message_chunk and agent_message_chunk hold the conversation, tool_call and tool_call_update the tools and their results."
    static let openCodeFormat = "Flight Deck's mirror of an OpenCode session, JSONL: one message per line"
    static let openCodeHowToRead = "Read the last 100 lines first (`tail -n 100`). \"type\":\"message\" records carry role and parts: text and reasoning parts hold the words, tool parts the call (state.input) and its result (state.output). prompt.asked / prompt.resolved records are permission requests and questions."

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

    static func grok(session: Session, home: URL,
                     exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> TranscriptPointer? {
        let url = GrokSessionFiles.transcriptURL(home: home, workingDirectory: session.transcriptDirectory,
                                                 conversationID: session.pinnedConversationID)
        guard exists(url.path) else { return nil }
        return TranscriptPointer(locator: .path(url.path), format: grokFormat, howToRead: grokHowToRead)
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

    /// The tab's mirror (`OpenCodeMirror`): the one OpenCode history that is a plain file. Not
    /// `opencode export`, which reads the built-in account's data unless `XDG_DATA_HOME` names
    /// the tab's, nor the server's message endpoint, which answers only with the account
    /// server's password — a hand-off reader has neither.
    static func openCode(session: Session,
                         exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> TranscriptPointer? {
        guard let path = session.transcriptPath, exists(path) else { return nil }
        return TranscriptPointer(locator: .path(path), format: openCodeFormat, howToRead: openCodeHowToRead)
    }
}
