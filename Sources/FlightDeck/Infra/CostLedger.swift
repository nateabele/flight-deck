import Foundation
import OSLog

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
    private let fileURL: URL
    private let calendar: Calendar

    private static let logger = Logger(subsystem: "dev.flightdeck.FlightDeck", category: "infra")

    private struct File: Codable {
        var version = 1
        var segments: [CostSegment]
    }

    init(fileURL: URL, calendar: Calendar = .current) {
        self.fileURL = fileURL
        self.calendar = calendar
        segments = Self.load(fileURL)
    }

    /// Closes any segment still open for `name` at `at` first, so one machine never bills twice.
    func open(name: String, hourlyUSD: Double, at: Date) throws {
        var next = Self.closing(segments, name: name, at: at)
        next.append(CostSegment(name: name, start: at, end: nil, hourlyUSD: hourlyUSD))
        try write(next)
        segments = next
    }

    func close(name: String, at: Date) throws {
        let next = Self.closing(segments, name: name, at: at)
        guard next != segments else { return }
        try write(next)
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

    private func write(_ segments: [CostSegment]) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(File(segments: segments)).write(to: fileURL, options: .atomic)
    }

    /// An unreadable ledger is moved aside, not zeroed: the next write would erase the spend history.
    private static func load(_ url: URL) -> [CostSegment] {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch CocoaError.fileReadNoSuchFile {
            return []
        } catch {
            moveAside(url, error)
            return []
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do { return try decoder.decode(File.self, from: data).segments } catch {
            moveAside(url, error)
            return []
        }
    }

    private static func moveAside(_ url: URL, _ error: Error) {
        let aside = url.deletingPathExtension().appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970)).json")
        try? FileManager.default.moveItem(at: url, to: aside)
        logger.error("infra-ledger.json unreadable, moved aside: \(String(describing: error), privacy: .public)")
    }
}
