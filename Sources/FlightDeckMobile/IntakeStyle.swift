import FleetKit
import Foundation

enum IntakeTone: Equatable { case live, attention, failure, quiet }
struct IntakeGlyph: Equatable { let symbol: String; let tone: IntakeTone }

/// The Sessions list's intake rows, as decisions (MOBILE-UI: a decision reachable without
/// SwiftUI is one a test can run). Words follow spec §3: tasks, agents, Flight Control.
enum IntakeRowStyle {
    static func ordered(_ intakes: [WireIntakeSummary]) -> [WireIntakeSummary] {
        func rank(_ s: WireIntakeSummary) -> Int {
            if s.needsAttention { return 0 }
            if s.runStatus == "running" || s.runStatus == "paused" || s.state == "triaging" { return 1 }
            return 2
        }
        return intakes.sorted { a, b in
            rank(a) != rank(b) ? rank(a) < rank(b) : a.createdAt > b.createdAt
        }
    }

    static func badge(_ intakes: [WireIntakeSummary]?) -> String? {
        let n = intakes?.filter(\.needsAttention).count ?? 0
        return n == 0 ? nil : "\(n) \(n == 1 ? "needs" : "need") you"
    }

    static func presetName(_ raw: String?) -> String? {
        switch raw {
        case "bead": "Single task"
        case "sketch": "Sketch"
        case "featurePlan": "Feature plan"
        case "fullPlan": "Full plan"
        case nil: nil
        default: raw
        }
    }

    static func glyph(_ s: WireIntakeSummary) -> IntakeGlyph {
        switch s.state {
        case "failed", "interrupted": IntakeGlyph(symbol: "exclamationmark", tone: .failure)
        case "needsAnswers": IntakeGlyph(symbol: "questionmark", tone: .attention)
        case "awaitingChoice", "review", "partiallyReleased": IntakeGlyph(symbol: "diamond", tone: .attention)
        case "released": IntakeGlyph(symbol: "checkmark", tone: .quiet)
        default:
            if s.needsAttention { IntakeGlyph(symbol: "pause.fill", tone: .attention) }
            else if s.runStatus == "running" || s.state == "triaging" { IntakeGlyph(symbol: "airplane", tone: .live) }
            else { IntakeGlyph(symbol: "pause.fill", tone: .quiet) }
        }
    }

    /// Whether a row's clock may drop to once a minute (`ClockPolicy.tickInterval`): only an
    /// intake that is working — a running round, or triage — needs a second hand.
    static func clockIsIdle(_ s: WireIntakeSummary) -> Bool {
        s.runStatus != "running" && s.state != "triaging"
    }

    static func stateWord(_ s: WireIntakeSummary) -> String {
        switch s.state {
        case "triaging": "Triaging"
        case "needsAnswers": "Needs answers"
        case "awaitingChoice": "Choose fidelity"
        case "parked": "Parked"
        case "shaping": s.runStatus == "running" ? "Shaping" : s.needsAttention ? "Paused" : "Shaping"
        case "review": "Ready for review"
        case "releasing": "Releasing"
        case "released": "Released"
        case "partiallyReleased": "Partly released"
        case "failed": "Failed"
        case "interrupted": "Interrupted"
        default: "Flight Control"
        }
    }

    static func pill(_ s: WireIntakeSummary) -> String {
        s.state == "shaping" ? (s.now ?? "Shaping") : stateWord(s)
    }

    static func fact(_ s: WireIntakeSummary, clock: String?) -> String? {
        switch s.state {
        case "needsAnswers":
            return s.questionCount.map { "\($0) question\($0 == 1 ? "" : "s")" }
        case "released", "partiallyReleased":
            return s.releasedTaskCount.map { "Released \($0) task\($0 == 1 ? "" : "s")" }
        case "shaping":
            var parts = [s.now, clock].compactMap { $0 }
            if let d = s.agentsDone, let t = s.agentsTotal { parts.append("\(d) of \(t) agents") }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        default:
            return nil
        }
    }
}

struct IntakeBanner: Equatable, Identifiable {
    let id: UUID
    let project: String
    let title: String
    let subtitle: String
}

/// In-app attention (spec §4.2, D4). A banner is a TRANSITION heard live: an intake the phone
/// already knew, which did not need you, now does. Never from a snapshot — a reconnect would
/// otherwise announce everything already waiting — and never over that intake's own screen.
enum BannerPolicy {
    static func banners(previous: [UUID: WireIntakeSummary], next: [WireIntakeSummary],
                        project: String, onScreen: UUID?) -> [IntakeBanner] {
        next.compactMap { s in
            guard s.needsAttention, let before = previous[s.id], !before.needsAttention, s.id != onScreen else { return nil }
            let words: String = switch s.state {
            case "needsAnswers": "needs answers"
            case "awaitingChoice": "is ready to plan"
            case "review", "partiallyReleased": "is ready for review"
            case "failed": "failed"
            case "interrupted": "was interrupted"
            default: "is paused"
            }
            let fact = IntakeRowStyle.fact(s, clock: nil) ?? IntakeRowStyle.stateWord(s)
            return IntakeBanner(id: s.id, project: project, title: "\(s.title) \(words)", subtitle: "\(project) · \(fact)")
        }
    }
}

/// Count-up clocks (spec §3). `offset` is the Mac's clock minus the phone's, from the last
/// detail's `servedAt`, so skew never shows; `frozenAt` is when the link was lost.
enum ClockPolicy {
    static func elapsed(since: Date, now: Date, offset: TimeInterval, frozenAt: Date?) -> TimeInterval {
        let end = (frozenAt ?? now).addingTimeInterval(offset)
        return max(0, end.timeIntervalSince(since))
    }

    static func text(_ interval: TimeInterval) -> String {
        let t = Int(interval.rounded(.down))
        let (h, m, s) = (t / 3600, (t % 3600) / 60, t % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    static func tickInterval(elapsed: TimeInterval, idle: Bool) -> TimeInterval {
        idle && elapsed > 60 ? 60 : 1
    }
}
