import FleetKit
import Foundation

/// What a claude session is blocked on, derived on the Mac from a window of its transcript.
///
/// **Deliberately the phone's derivation and not a second one.** The lines are mapped with
/// `ClaudeTimelineMapper` — the same mapper whose output the phone receives as a page — and
/// then handed to `OpenPrompt.find`, the same function the phone runs over its feed. Nothing
/// here re-implements the call/result pairing or the question parse. Two implementations of
/// one rule is how the Mac ends up typing an answer at a dialog the phone was not looking at,
/// which is the specific failure this whole feature has to not have.
///
/// **The window is a tail, and that is exact rather than a shortcut.** Claude cannot proceed
/// past a dialog, so the open call is always among the last records; a read of a handful of
/// them either finds it or proves there is none. A few rather than one, so that a
/// `tool_result` for an *earlier* call is in the window and cannot make an already-answered
/// call look open — the only way this can be wrong in the dangerous direction.
enum ClaudeOpenCall {
    static func find(in lines: [SourceLine], activity: SessionActivity?) -> OpenPrompt? {
        let items = lines.flatMap { ClaudeTimelineMapper.items(inLine: $0.text, at: $0.offset) }
        return OpenPrompt.find(
            in: items, agent: AgentID.claude.rawValue, activity: activity?.rawValue
        )
    }
}

/// Claude's conformance to `AgentOpenPromptReader`. Two lines, and deliberately a separate
/// type from `ClaudeOpenCall` itself: that enum is the pure derivation and is reached from
/// tests directly, while this is the capability the adapter hands out.
struct ClaudeOpenPromptReader: AgentOpenPromptReader {
    func openPrompt(
        inTranscriptTail lines: [SourceLine], activity: SessionActivity?
    ) -> OpenPrompt? {
        ClaudeOpenCall.find(in: lines, activity: activity)
    }
}
