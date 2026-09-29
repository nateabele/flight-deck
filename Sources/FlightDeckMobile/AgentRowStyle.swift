import FleetKit
import Foundation

enum AgentException: Equatable {
    case quiet(TimeInterval)
    case stalled(TimeInterval, last: String?)
    case rateLimited(TimeInterval)
    case fallback(String)
    case failed(String)
}

/// An agent row's exception, judged on the phone with the Mac's precedence
/// (`SeatRowModel.runningException`: rate limit > stalled > fallback > quiet) and the shared
/// `AgentActivityRules`. `now` is the caller's skew-corrected clock.
enum AgentRowStyle {
    static func finished(_ a: WireAgent) -> Bool { a.glyph == "done" || a.glyph == "failed" }

    static func exception(_ a: WireAgent, now: Date) -> AgentException? {
        if finished(a) { return a.failure.map(AgentException.failed) }
        if let at = a.rateLimitedAt { return .rateLimited(max(0, now.timeIntervalSince(at))) }
        guard let started = a.startedAt else { return nil }
        let idle = max(0, now.timeIntervalSince(a.lastEventAt ?? started))
        if idle >= AgentActivityRules.stalled { return .stalled(idle, last: a.action) }
        if let fallback = a.fallback { return .fallback(fallback) }
        if idle >= AgentActivityRules.quiet { return .quiet(idle) }
        return nil
    }

    static func exceptionText(_ e: AgentException) -> String {
        switch e {
        case .quiet(let t): "quiet \(ClockPolicy.text(t))"
        case .stalled(let t, let last): "No output for \(ClockPolicy.text(t))" + (last.map { " · last: \($0)" } ?? "")
        case .rateLimited(let t): "Waiting on rate limit · \(ClockPolicy.text(t))"
        case .fallback(let text): text
        case .failed(let text): text
        }
    }

    static func isAmber(_ e: AgentException) -> Bool {
        switch e {
        case .quiet, .failed: false
        case .stalled, .rateLimited, .fallback: true
        }
    }

    static func elapsed(_ a: WireAgent, now: Date) -> TimeInterval {
        if let d = a.duration { return d }
        guard let started = a.startedAt else { return 0 }
        return max(0, now.timeIntervalSince(started))
    }

    static func accessibilityLabel(_ a: WireAgent, now: Date) -> String {
        var parts = ["\(a.role.capitalized), \(a.identity.replacingOccurrences(of: " · ", with: ", "))"]
        if let h = a.headline ?? a.result { parts.append(h) }
        if let action = a.action, !finished(a) { parts.append(action) }
        if let e = exception(a, now: now) { parts.append(exceptionText(e)) }
        return parts.joined(separator: ". ")
    }
}
