import FleetKit
import Foundation
import IntakeKit

/// What an OpenCode tab is blocked on, derived from the tail of its mirror.
///
/// The phone's derivation, run on the Mac, for `ClaudeOpenCall`'s reason: the lines go through
/// `OpenCodeTimelineMapper` — the mapper whose output the phone receives — and then into
/// `OpenPrompt.find`, the function the phone runs over that feed. One rule, one implementation.
///
/// It works because the mirror logs OpenCode's requests as `prompt.asked` / `prompt.resolved`
/// records keyed by the REQUEST id (`per_…`, `que_…`), and the mapper turns those into a call
/// and its result. So the call id the phone's card carries back is the id OpenCode's reply
/// endpoint takes, and `OpenCodePromptResponder` needs no lookup to answer it.
struct OpenCodeOpenPromptReader: AgentOpenPromptReader {
    func openPrompt(inTranscriptTail lines: [SourceLine], activity: SessionActivity?) -> OpenPrompt? {
        let items = lines.flatMap { OpenCodeTimelineMapper.items(inLine: $0.text, at: $0.offset) }
        return OpenPrompt.find(
            in: items, agent: AgentID.opencode.rawValue, activity: activity?.rawValue
        )
    }

    /// **nil, because there is no second file to look in.** An OpenCode subagent is a child
    /// SESSION whose requests the runtime routes onto its root's tab and writes into the ROOT's
    /// mirror (`OpenCodeRuntime.apply(_:toChildOf:)`), so a child's dialog is already in the
    /// lines `openPrompt(inTranscriptTail:)` reads — the gap this hook exists for is closed by
    /// construction.
    func subagentTranscripts(for transcript: URL) -> URL? { nil }

    func openPrompt(inSubagentTail lines: [SourceLine]) -> OpenPrompt? { nil }
}
