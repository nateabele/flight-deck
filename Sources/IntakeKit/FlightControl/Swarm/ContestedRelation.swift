import Foundation

public struct HeldReservation: Equatable, Sendable {
    public var pattern: String
    public var holder: String
    public var since: Date?
    public init(pattern: String, holder: String, since: Date?) { self.pattern = pattern; self.holder = holder; self.since = since }

    /// Whether this reservation covers `file`: the pattern is the file itself or a glob matching it.
    /// The one predicate contested detection and the swarm view share.
    public func covers(file: String) -> Bool { pattern == file || Glob.matches(pattern, file) }
}

/// The last guard block and the last BLOCKED: line one session produced (spec §7.4: "store the
/// last block per session").
public struct SessionSignals: Equatable, Sendable {
    public var guardBlock: GuardBlock?
    public var guardBlockAt: Date?
    public var blocked: String?
    public var blockedAt: Date?
    public init(guardBlock: GuardBlock? = nil, guardBlockAt: Date? = nil, blocked: String? = nil, blockedAt: Date? = nil) {
        self.guardBlock = guardBlock; self.guardBlockAt = guardBlockAt; self.blocked = blocked; self.blockedAt = blockedAt
    }
}

public struct Contest: Equatable, Sendable {
    public var file: String
    public var holder: String
    public var heldSince: Date?
    /// The guard's message, or the agent's BLOCKED: line, quoted in the drawer.
    public var message: String
    public var at: Date
    public init(file: String, holder: String, heldSince: Date?, message: String, at: Date) {
        self.file = file; self.holder = holder; self.heldSince = heldSince; self.message = message; self.at = at
    }
}

/// `*` and `?` stop at `/`; `**` crosses it. Everything else is literal.
public enum Glob {
    public static func matches(_ pattern: String, _ path: String) -> Bool {
        var regex = "^"
        var chars = Array(pattern)[...]
        while let c = chars.first {
            chars = chars.dropFirst()
            switch c {
            case "*":
                if chars.first == "*" { chars = chars.dropFirst(); regex += ".*" } else { regex += "[^/]*" }
            case "?": regex += "[^/]"
            default: regex += NSRegularExpression.escapedPattern(for: String(c))
            }
        }
        regex += "$"
        return path.range(of: regex, options: .regularExpression) != nil
    }
}

/// Spec §7.5. Not a `SessionStatus`: a contested agent can be busy (retrying) or idle (stopped
/// after BLOCKED:), and that status keeps meaning what it means.
public enum ContestedRelation {
    public static let recentWindow: TimeInterval = 600

    public static func contest(agent: String, signals: SessionSignals, reservations: [HeldReservation], now: Date) -> Contest? {
        if let block = signals.guardBlock, let at = signals.guardBlockAt,
           now.timeIntervalSince(at) <= recentWindow, block.holder != agent {
            let held = reservations.first {
                $0.holder == block.holder && ($0.pattern == block.pattern || $0.covers(file: block.file))
            }
            return Contest(file: block.file, holder: block.holder, heldSince: held?.since, message: block.message, at: at)
        }
        if let text = signals.blocked, let at = signals.blockedAt, now.timeIntervalSince(at) <= recentWindow {
            for token in pathTokens(text) {
                if let held = reservations.first(where: { $0.holder != agent && $0.covers(file: token) }) {
                    return Contest(file: token, holder: held.holder, heldSince: held.since, message: "BLOCKED: " + text, at: at)
                }
            }
        }
        return nil
    }

    /// Words that look like paths: they contain `/` or `.`, with surrounding punctuation removed.
    static func pathTokens(_ text: String) -> [String] {
        text.components(separatedBy: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ",;()\"'`")))
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".:")) }
            .filter { !$0.isEmpty && ($0.contains("/") || $0.contains(".")) }
    }
}
