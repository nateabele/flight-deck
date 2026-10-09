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

    /// The derivation `PromptService` calls: the tab's own, unless a running subagent holds the
    /// card on screen.
    ///
    /// grok draws a subagent's permission card in the parent's TUI but writes its call only to
    /// the child's files (probed, facts-2 §4), so the parent's newest open call is the tool it
    /// waits on the child with — `get_command_or_subagent_output` or `spawn_subagent` — and an
    /// Allow drawn from that would name the wrong action. When exactly one running child holds an
    /// unresolved permission, ITS open call is the prompt: that is the card on screen, and
    /// answering it is the same keyed "Yes" on the same screen.
    ///
    /// Refuses (nil) when it cannot tell which card is up: two children holding cards, or the
    /// parent's own open call being some other tool. A child's QUESTION card was not probed, so
    /// only a child permission is offered.
    func openPrompt(inTranscriptAt url: URL, tail lines: [SourceLine], activity: SessionActivity?) -> OpenPrompt? {
        let own = openPrompt(inTranscriptTail: lines, activity: activity)
        guard activity == .waiting else { return own }
        let holders = childrenHoldingPermission(url)
        guard !holders.isEmpty else { return own }
        guard holders.count == 1 else { return nil }
        if case .permission(_, let tool, _)? = own, !GrokSubagents.waitingTools.contains(tool ?? "") {
            return nil
        }
        return childPrompt(holders[0])
    }

    /// A card-holding child's open call, offered only as a permission: a child's question card
    /// was never probed.
    private func childPrompt(_ directory: URL) -> OpenPrompt? {
        let child = openPrompt(
            inTranscriptTail: GrokSubagents.tailLines(of: directory.appendingPathComponent(GrokSessionFiles.transcriptName)),
            activity: .waiting)
        guard case .permission? = child else { return nil }
        return child
    }

    /// The child whose call `open` is, so the phone reads that child's file for the card — the
    /// parent's own timeline never holds it.
    func owningSubagent(of open: OpenPrompt, inTranscriptAt url: URL) -> String? {
        guard case .permission = open else { return nil }
        return childrenHoldingPermission(url)
            .first { childPrompt($0)?.callID == open.callID }?
            .lastPathComponent
    }

    /// A child's card, vouched for by the child's own `events.jsonl` (an unresolved
    /// `permission_requested`) rather than by a hook log, which grok tabs do not have.
    func vouchedSubagentPrompt(inTranscriptAt url: URL, agent: String) -> OpenPrompt? {
        guard GrokSubagents.isChildID(agent),
              let holder = childrenHoldingPermission(url).first(where: { $0.lastPathComponent == agent })
        else { return nil }
        return childPrompt(holder)
    }

    /// A child's `updates.jsonl`, for the phone's view of the card — only for a child THIS
    /// session spawned, so a phone cannot name any other grok session by id and read it.
    func subagentTranscript(for transcript: URL, agent: String) -> URL? {
        guard GrokSubagents.isChildID(agent),
              GrokSubagents.isChild(agent, ofSessionDirectory: transcript.deletingLastPathComponent()),
              let dir = GrokSubagents.childDirectory(agent, sessionsRoot: GrokSessionFiles.sessionsRoot(ofTranscript: transcript))
        else { return nil }
        return dir.appendingPathComponent(GrokSessionFiles.transcriptName)
    }

    /// The running children holding a card, injectable so a test can stand without a sessions
    /// tree. Production reads `<session>/subagents/*/meta.json` and each child's `events.jsonl`.
    var childrenHoldingPermission: @Sendable (URL) -> [URL] = { GrokSubagents.childrenHoldingPermission(ofTranscript: $0) }

    /// grok's subagents are sessions with their own directories, not `agent-<id>.jsonl` files in
    /// one folder, which is the layout this member names (claude's); `subagentTranscript(for:agent:)`
    /// above names a child's file instead.
    func subagentTranscripts(for transcript: URL) -> URL? { nil }

    func openPrompt(inSubagentTail lines: [SourceLine]) -> OpenPrompt? { nil }

    /// The pending `tool_call` is in the transcript; `waiting` says it is a dialog. A subagent's
    /// card is in the CHILD's transcript, which the phone fetches because the card is attributed
    /// to the child (`owningSubagent`) — so the words never need to travel for grok either.
    var transcriptCarriesOpenPrompt: Bool { true }

    /// The running children's `events.jsonl` sizes and dates: a child's next card is written
    /// there and in the child's transcript, not the parent's, so the parent's stamp alone would
    /// let `PromptService` serve the card the child has moved on from. One `stat` of the
    /// `subagents/` directory for a session that never spawned one.
    func auxiliaryStamp(forTranscriptAt url: URL) -> String? {
        GrokSubagents.stamp(ofTranscript: url)
    }
}
