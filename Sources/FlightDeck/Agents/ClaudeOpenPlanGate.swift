import FleetKit
import Foundation

/// The open `ExitPlanMode` call for a claude session, derived from its transcript tail.
///
/// **Deliberately not `ClaudeOpenCall`/`OpenPrompt.find`.** Those gate on
/// `activity == "waiting"` — exact for a dialog, and exactly wrong for a plan gate, which is
/// the one call a hook blocks *without* claude ever reporting `waiting`. That is the defect
/// this whole feature exists to fix (see `SessionNotificationPolicy`), so re-deriving through
/// the activity-gated path would reproduce it inside the fix. This walks the same
/// `ClaudeTimelineMapper` items and pairs calls with results the same way — last unanswered
/// `ExitPlanMode` wins — but never asks what claude's status file says.
enum ClaudeOpenPlanGate {
    /// `find(in:)` over a tail that widens until it finds the call or runs out of file —
    /// `PromptService.scan`'s loop, with its start, growth and three stops.
    ///
    /// **A fixed `PromptService.tailRecords` window lost a live gate.** Claude writes six
    /// bookkeeping lines after every turn (`last-prompt`, `custom-title`, `agent-name`, `mode`,
    /// `permission-mode`, `atis-latch`) and appends a `queue-operation` line for each message
    /// queued while the gate is open — a background task finishing, another session's
    /// message. Two of those were enough (2026-10-09, "The Plan"): the open `ExitPlanMode`
    /// sat ninth from the end, this read nil, and the phone never drew its banner while
    /// `PromptService`, which widens, reported the same call open. Only ever asked for a
    /// session the registry already shows a live plan gate for, so a miss that climbs to the
    /// ceiling is as rare as the gate is.
    ///
    /// Widening cannot surface an older plan over the open one: every wider read is a
    /// superset that still contains the narrower window, and `find(in:)` prefers the newest
    /// unanswered call, so the first window that holds the open call returns it.
    static func find(tail: (Int) -> (lines: [SourceLine], hasMore: Bool)) -> String? {
        var limit = max(1, PromptService.tailRecords)
        var previousCount = -1
        while true {
            let (lines, hasMore) = tail(limit)
            if let call = find(in: lines) { return call }
            guard hasMore, limit < PromptService.maxTailRecords, lines.count > previousCount
            else { return nil }
            previousCount = lines.count
            limit *= 8
        }
    }

    static func find(in lines: [SourceLine]) -> String? {
        let items = lines.flatMap { ClaudeTimelineMapper.items(inLine: $0.text, at: $0.offset) }

        var answered: Set<String> = []
        for item in items where item.kind == .toolResult {
            if let id = item.body.callID { answered.insert(id) }
        }

        // Reversed, and — unlike `OpenPrompt.find` — skipping straight past any unanswered
        // call that is not `ExitPlanMode`, rather than stopping at the first unanswered item
        // regardless of tool. That divergence is deliberate, not an oversight: `OpenPrompt`
        // treats the newest unanswered call as having *superseded* whatever else is open,
        // because a person answering a dialog can raise a new one in the same breath. A gate
        // has no such successor to be superseded by. `ExitPlanMode` blocks the tool loop until
        // it resolves, so nothing this session writes can be a later, truer plan call than an
        // unanswered `ExitPlanMode` still sitting in the tail — a younger unanswered call of a
        // different tool is a sibling from the same blocked turn (parallel tool calls in one
        // message), not a call claude went on to make afterward. And this is only ever asked
        // of a transcript `PlanGateService.refresh()` has already matched to a gate the
        // registry independently confirms is open for this pid — so skipping past the
        // stranger to keep looking for the real one is the correct read of what is on screen,
        // not a guess.
        for item in items.reversed() {
            guard item.kind == .toolCall, item.body.tool == "ExitPlanMode",
                  let id = item.body.callID, !answered.contains(id)
            else { continue }
            return id
        }
        return nil
    }
}
