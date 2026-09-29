import FleetKit
import Foundation

/// The pinned strip's content (spec §4.3) — every word and colour decision, apart from the view.
struct BoardStripModel: Equatable {
    struct Dot: Equatable, Identifiable {
        let id: String
        let state: String
        let isStop: Bool
        let checkpoint: Int?
        let label: String
        var tappable: Bool { checkpoint != nil && state != "future" }
    }
    let nowText: String
    let clockCaption: String
    let clockSince: Date?
    let clockText: String?
    let stopText: String
    let convergence: String?
    let convergenceAmber: Bool
    let dots: [Dot]
    let tone: IntakeTone
    let idle: Bool

    init(detail: WireIntakeDetail) {
        let s = detail.summary
        let board = detail.board
        tone = s.state == "failed" || s.state == "interrupted" || s.runStatus == "failed" ? .failure
            : s.needsAttention ? .attention
            : (s.runStatus == "running" || s.state == "triaging") ? .live : .quiet
        idle = s.runStatus != "running" && s.state != "triaging"
        let now = (board?.nowName ?? s.now ?? IntakeRowStyle.stateWord(s)).uppercased()
        if let board, let live = board.slots.first(where: { $0.state == "live" }), let group = live.group {
            let inCycle = board.slots.filter { $0.group == group }
            nowText = "\(now) OF \(inCycle.count)"
        } else if s.state == "needsAnswers" || s.state == "awaitingChoice" {
            nowText = s.state == "needsAnswers" ? "\(now) · YOUR TURN" : "READY · PICK FIDELITY"
        } else if s.state == "review" {
            nowText = "REVIEW · READY FOR YOU"
        } else if s.runStatus == "paused" {
            nowText = "\(now) · PAUSED"
        } else {
            nowText = now
        }
        clockCaption = board?.clockCaption ?? (s.state == "triaging" ? "IN THE AIR" : "")
        clockSince = board?.clockSince ?? s.clockSince
        clockText = board?.clockText
        stopText = board.map { "→ STOPS AT \($0.stopsAt.uppercased())" } ?? ""
        convergence = board?.convergence?.word
        convergenceAmber = board?.convergence?.amber ?? false
        dots = (board?.slots ?? []).map { slot in
            let status = switch slot.state {
            case "done": "landed"
            case "live": "in the air"
            case "failed": "failed"
            default: "scheduled"
            }
            let duration = slot.duration.map { ", " + Self.spoken($0) } ?? ""
            return Dot(id: slot.id, state: slot.state, isStop: slot.id == board?.stopSlotID,
                       checkpoint: slot.checkpoint, label: "\(slot.name), \(status)\(duration)")
        }
    }

    static func spoken(_ t: TimeInterval) -> String {
        let s = Int(t), m = s / 60, r = s % 60
        return m == 0 ? "\(r) seconds" : "\(m) minute\(m == 1 ? "" : "s") \(r)"
    }
}
