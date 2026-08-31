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
    static func find(in lines: [SourceLine]) -> String? {
        let items = lines.flatMap { ClaudeTimelineMapper.items(inLine: $0.text, at: $0.offset) }

        var answered: Set<String> = []
        for item in items where item.kind == .toolResult {
            if let id = item.body.callID { answered.insert(id) }
        }

        // Reversed: the newest unanswered call is the live one, exactly as `OpenPrompt.find`
        // reads its window — a superseded call earlier in the tail must not win over one that
        // followed it.
        for item in items.reversed() {
            guard item.kind == .toolCall, item.body.tool == "ExitPlanMode",
                  let id = item.body.callID, !answered.contains(id)
            else { continue }
            return id
        }
        return nil
    }
}
