import FleetKit
import Foundation

/// The round detail's facts strip (spec §4.6): the same four fields for every round, "—" for a
/// missing one on screen and words for it to VoiceOver.
struct RoundFacts: Equatable {
    let time: String
    let changes: String
    let lines: String
    let verdicts: String
    let spoken: String

    init(_ r: WireRound) {
        let duration = r.startedAt.map { r.landedAt.timeIntervalSince($0) }
        time = duration.map(ClockPolicy.text) ?? "—"
        changes = r.changeCount.map(String.init) ?? "—"
        let hasLines = r.linesAdded > 0 || r.linesRemoved > 0
        lines = hasLines ? "+\(r.linesAdded) −\(r.linesRemoved)" : "—"
        verdicts = r.verdicts.map { "\($0.agreed) · \($0.somewhat) · \($0.declined)" } ?? "—"
        spoken = [
            duration.map(BoardStripModel.spoken) ?? "no duration recorded",
            r.changeCount.map { "\($0) changes" } ?? "no change count",
            hasLines ? "\(r.linesAdded) lines added and \(r.linesRemoved) removed" : "no line counts",
            r.verdicts.map { "\($0.agreed) agreed, \($0.somewhat) somewhat, \($0.declined) declined" } ?? "no verdicts",
        ].joined(separator: ", ")
    }
}
