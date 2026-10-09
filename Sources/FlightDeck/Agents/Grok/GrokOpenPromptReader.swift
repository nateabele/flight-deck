import FleetKit
import Foundation
import IntakeKit

/// What a grok session is blocked on, derived from a window of its `updates.jsonl`.
///
/// The phone's derivation, run on the Mac over the same mapper — `ClaudeOpenCall`'s rule for
/// the same reason: one implementation of the call/result pairing. grok writes a `tool_call`
/// AT RAISE, before its permission card goes up, and a `tool_call_update` with a terminal
/// status once it is answered and run (probed), so "an unanswered call while the tab is
/// `waiting`" names the card.
///
/// **`waiting` is what separates a pending approval from a tool that is merely running**: the
/// transcript alone cannot (facts §4). It comes from `events.jsonl` — a `permission_requested`
/// with no `permission_resolved` — or from an open `ask_user_question`, folded by
/// `GrokStatusFold`, never from this file.
struct GrokOpenPromptReader: AgentOpenPromptReader {
    func openPrompt(inTranscriptTail lines: [SourceLine], activity: SessionActivity?) -> OpenPrompt? {
        let items = lines.flatMap { GrokTimelineMapper.items(inLine: $0.text, at: $0.offset) }
        return OpenPrompt.find(in: items, agent: AgentID.grok.rawValue, activity: activity?.rawValue)
    }

    /// grok's subagents run as sessions of their own with their own cards (user guide ch. 16);
    /// none was probed, so none is claimed. nil is "this agent has no such files", which is the
    /// honest answer for what this build can read.
    func subagentTranscripts(for transcript: URL) -> URL? { nil }

    func openPrompt(inSubagentTail lines: [SourceLine]) -> OpenPrompt? { nil }

    /// The pending `tool_call` is in the transcript; `waiting` says it is a dialog.
    var transcriptCarriesOpenPrompt: Bool { true }
}
