import Foundation

/// One stretch of a machine billing at one rate. A rate change is a new segment, never an
/// edit, so hours already spent are not repriced.
struct CostSegment: Codable, Equatable, Sendable {
    let name: String
    let start: Date
    var end: Date?
    let hourlyUSD: Double
}

/// What the machines cost: `infra-ledger.json`, apart from `infra.json` so the history
/// outlives a machine's registry entry. An open segment is billed up to `now`.
@MainActor
final class CostLedger {
    private var segments: [CostSegment]
    private let file: VersionedJSONFile<CostSegment>
    private let calendar: Calendar

    init(fileURL: URL, calendar: Calendar = .current) {
        file = VersionedJSONFile(url: fileURL, key: "segments")
        self.calendar = calendar
        segments = file.load()
    }

    /// Closes any segment still open for `name` at `at` first, so one machine never bills twice.
    func open(name: String, hourlyUSD: Double, at: Date) throws {
        var next = Self.closing(segments, name: name, at: at)
        next.append(CostSegment(name: name, start: at, end: nil, hourlyUSD: hourlyUSD))
        try file.write(next)
        segments = next
    }

    func close(name: String, at: Date) throws {
        let next = Self.closing(segments, name: name, at: at)
        guard next != segments else { return }
        try file.write(next)
        segments = next
    }

    func spent(name: String, now: Date) -> Double {
        segments.filter { $0.name == name }.reduce(0) { $0 + Self.cost($1, from: .distantPast, to: now) }
    }

    /// Only the part of each segment inside `[start of now's month, now]`, so a machine that
    /// crossed midnight on the 1st counts only its new-month hours.
    func monthToDate(now: Date) -> Double {
        let start = calendar.dateInterval(of: .month, for: now)?.start ?? .distantPast
        return segments.reduce(0) { $0 + Self.cost($1, from: start, to: now) }
    }

    private static func cost(_ s: CostSegment, from: Date, to now: Date) -> Double {
        let lo = max(s.start, from), hi = min(s.end ?? now, now)
        return hi > lo ? s.hourlyUSD * hi.timeIntervalSince(lo) / 3600 : 0
    }

    private static func closing(_ segments: [CostSegment], name: String, at: Date) -> [CostSegment] {
        segments.map { s in
            guard s.name == name, s.end == nil else { return s }
            var closed = s
            closed.end = max(at, s.start)
            return closed
        }
    }
}
