import Foundation

/// A span written the way people write it in config: `45s`, `30m`, `4h`, `1d`, or a run of
/// them (`1h30m`). Whole units only, all positive — a TTL of `1.5h` or `0m` is a typo, not
/// a request, and a machine that bills by the hour must never get one silently. Units run
/// largest first, each at most once: `1m1h` or `30m30m` is a slip for some other span, and
/// summing it would bill one nobody wrote.
public struct Duration: Codable, Sendable, Equatable, Comparable {
    public let seconds: Int
    public init(seconds: Int) { self.seconds = seconds }

    private static let units: [(Character, Int)] = [("d", 86_400), ("h", 3600), ("m", 60), ("s", 1)]

    public static func parse(_ text: String) -> Duration? {
        var total = 0, digits = "", sawUnit = false
        // Index into `units` that the next unit must come after; enforces order and uniqueness.
        var nextUnit = 0
        for ch in text {
            if ch.isASCII, ch.isNumber { digits.append(ch); continue }
            guard let index = units.firstIndex(where: { $0.0 == ch }), index >= nextUnit,
                  let n = Int(digits), n > 0 else { return nil }
            let unit = units[index]
            nextUnit = index + 1
            // Overflow is a typo too (`9999999999999999d`), and must not trap the parser.
            let (span, mulOverflow) = n.multipliedReportingOverflow(by: unit.1)
            let (sum, addOverflow) = total.addingReportingOverflow(span)
            if mulOverflow || addOverflow { return nil }
            total = sum; digits = ""; sawUnit = true
        }
        guard sawUnit, digits.isEmpty, total > 0 else { return nil }
        return Duration(seconds: total)
    }

    public var formatted: String {
        var rest = seconds, out = ""
        for (symbol, size) in Self.units where rest >= size {
            out += "\(rest / size)\(symbol)"; rest %= size
        }
        return out.isEmpty ? "0s" : out
    }

    public static func < (a: Duration, b: Duration) -> Bool { a.seconds < b.seconds }
}
