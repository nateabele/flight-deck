import Foundation

/// One row as the extraction agent reported it, before validation. `url`, `retrievedAt` and
/// `quotedFigure` are optional HERE so a row missing one is rejected with a reason, instead of
/// failing the whole answer's decode and losing every good row beside it.
public struct ExtractedRow: Codable, Equatable, Sendable {
    public var benchmarkModel: String
    public var score: Double
    public var unit: String
    public var url: String?
    public var retrievedAt: String?
    public var quotedFigure: String?
    public init(benchmarkModel: String, score: Double, unit: String, url: String?, retrievedAt: String?, quotedFigure: String?) {
        self.benchmarkModel = benchmarkModel; self.score = score; self.unit = unit
        self.url = url; self.retrievedAt = retrievedAt; self.quotedFigure = quotedFigure
    }
}

/// The agent's whole answer for one source: `{"source": …, "rows": […]}`.
public struct ExtractionPayload: Codable, Equatable, Sendable {
    public var source: String
    public var rows: [ExtractedRow]
    public init(source: String, rows: [ExtractedRow]) { self.source = source; self.rows = rows }
}

/// A row that passed: it names a model, cites where it was read, and its quoted figure is its
/// score. Only these are ever scored or stored as a snapshot's raw rows.
public struct AcceptedRow: Codable, Equatable, Sendable {
    public var benchmarkModel: String
    public var score: Double
    public var unit: IndexUnit
    public var url: String
    public var retrievedAt: String?
    public var quotedFigure: String
    public init(benchmarkModel: String, score: Double, unit: IndexUnit, url: String, retrievedAt: String?, quotedFigure: String) {
        self.benchmarkModel = benchmarkModel; self.score = score; self.unit = unit
        self.url = url; self.retrievedAt = retrievedAt; self.quotedFigure = quotedFigure
    }
}

public struct RejectedRow: Codable, Equatable, Sendable {
    public var row: ExtractedRow
    public var reason: String
    public init(row: ExtractedRow, reason: String) { self.row = row; self.reason = reason }
}

/// Decides which extracted rows the index may believe.
///
/// The quoted-figure check is the one that catches a model inventing numbers: the agent must
/// copy the figure character for character, and the figure must parse back to the score it
/// claims. A hallucinated score rarely comes with a matching quotation of the page.
public enum ExtractionValidator {
    public static func validate(_ payload: ExtractionPayload, for source: IndexSource)
        -> (accepted: [AcceptedRow], rejected: [RejectedRow]) {
        var accepted: [AcceptedRow] = []
        var rejected: [RejectedRow] = []
        for row in payload.rows {
            if let reason = rejection(row, payloadSource: payload.source, source: source) {
                rejected.append(RejectedRow(row: row, reason: reason))
            } else {
                guard let unit = IndexUnit(rawValue: row.unit) else {
                    rejected.append(RejectedRow(row: row, reason: "unknown unit \(row.unit)"))
                    continue
                }
                accepted.append(AcceptedRow(benchmarkModel: row.benchmarkModel.trimmingCharacters(in: .whitespaces),
                                            score: row.score, unit: unit,
                                            url: (row.url ?? "").trimmingCharacters(in: .whitespaces),
                                            retrievedAt: row.retrievedAt, quotedFigure: row.quotedFigure ?? ""))
            }
        }
        return (accepted, rejected)
    }

    /// Why `row` is rejected, or nil. Checked in this order so the reason names the most basic
    /// fault first: provenance before units before the figure.
    public static func rejection(_ row: ExtractedRow, payloadSource: String, source: IndexSource) -> String? {
        if payloadSource != source.id { return "payload is for \(payloadSource), not \(source.id)" }
        guard let url = row.url?.trimmingCharacters(in: .whitespaces), !url.isEmpty else { return "missing url" }
        guard url.hasPrefix("https://") || url.hasPrefix("http://") else { return "url is not a web address: \(url)" }
        guard IndexUnit(rawValue: row.unit) != nil else { return "unknown unit \(row.unit)" }
        guard row.unit == source.unit else { return "unit \(row.unit) but \(source.id) reads \(source.unit)" }
        if row.benchmarkModel.trimmingCharacters(in: .whitespaces).isEmpty { return "missing benchmarkModel" }
        guard row.score.isFinite else { return "score is not a number" }
        guard let figure = row.quotedFigure, figureMatches(figure, score: row.score) else {
            let quoted = row.quotedFigure.map { "\"\($0)\"" } ?? "missing"
            return "quoted figure \(quoted) does not match score \(row.score)"
        }
        return nil
    }

    /// The first number in `text`, and how many decimals it was written with. Thousands commas
    /// are skipped. Hand-rolled rather than a regex: IntakeKit is Swift 6, and a shared
    /// `NSRegularExpression` is not `Sendable`.
    public static func parseFigure(_ text: String) -> (value: Double, decimals: Int)? {
        let chars = Array(text)
        func isDigit(_ i: Int) -> Bool { i < chars.count && chars[i].isASCII && chars[i].isNumber }
        var digits = ""
        var decimals = 0
        var seenDot = false
        var i = 0
        while i < chars.count, !isDigit(i) { i += 1 }
        guard i < chars.count else { return nil }
        while i < chars.count {
            let c = chars[i]
            if isDigit(i) {
                digits.append(c)
                if seenDot { decimals += 1 }
            } else if c == ",", !seenDot, isDigit(i + 1) {
                // A thousands separator: "1,234".
            } else if c == ".", !seenDot, isDigit(i + 1) {
                seenDot = true
                digits.append(".")
            } else {
                break
            }
            i += 1
        }
        guard let value = Double(digits) else { return nil }
        return (value, decimals)
    }

    /// True when `score` lies within half a unit of the quoted figure's last written digit — the
    /// figure, at the precision it was quoted, contains the score. "61.3%" admits 61.25…61.35.
    public static func figureMatches(_ figure: String, score: Double) -> Bool {
        guard let (value, decimals) = parseFigure(figure) else { return false }
        let halfStep = 0.5 / pow(10, Double(decimals))
        return abs(score - value) <= halfStep + 1e-9
    }
}
