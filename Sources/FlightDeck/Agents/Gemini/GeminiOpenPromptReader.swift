import FleetKit
import Foundation

/// What an agy tab is blocked on, read from the conversation's step store.
///
/// **The transcript cannot answer this, which is why this reader needs the transcript's PATH
/// rather than its lines.** agy writes a step to `transcript_full.jsonl` only once it is DONE,
/// ERROR or similar; a step WAITING on the user's approval is in `conversations/<id>.db` alone,
/// as a row with status 9 whose payload names the call (agy-tui-facts §4). So the window of
/// lines `PromptService` reads is ignored, and `openPrompt(inTranscriptAt:…)` goes from the
/// transcript's path to the conversation's step store, read-only.
///
/// Every agy approval is a permission (allow/deny); agy has no `AskUserQuestion` equivalent in
/// any capture, so this never produces `.question`.
struct GeminiOpenPromptReader: AgentOpenPromptReader {
    /// The store read, injectable so a test needs no SQLite file.
    var pendingCall: @Sendable (URL) -> GeminiPendingCall? = { GeminiStepStore.pendingCall(in: $0) }

    func openPrompt(inTranscriptAt url: URL, tail lines: [SourceLine], activity: SessionActivity?) -> OpenPrompt? {
        guard activity == .waiting, let conversation = GeminiPaths.conversation(ofTranscript: url),
              let call = pendingCall(conversation.paths.stepStore(conversation.id))
        else { return nil }
        return Self.prompt(for: call)
    }

    static func prompt(for call: GeminiPendingCall) -> OpenPrompt {
        let args = (try? JSONSerialization.jsonObject(with: Data(call.argumentsJSON.utf8))) as? [String: Any] ?? [:]
        let summary = (args["toolSummary"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? ToolInputSummary.text(for: args)
        return .permission(callID: call.callID, tool: call.tool, summary: summary)
    }

    /// No path, no store: nothing can be derived from lines alone (see the type's comment).
    func openPrompt(inTranscriptTail lines: [SourceLine], activity: SessionActivity?) -> OpenPrompt? { nil }

    /// agy's subagents run as separate conversations (`parent_conversation_id` in the summaries
    /// index), each with its own step store; none of their dialogs is drawn in a parent tab in
    /// any capture, so there is no subagent file to look in.
    func subagentTranscripts(for transcript: URL) -> URL? { nil }
    func openPrompt(inSubagentTail lines: [SourceLine]) -> OpenPrompt? { nil }
}
