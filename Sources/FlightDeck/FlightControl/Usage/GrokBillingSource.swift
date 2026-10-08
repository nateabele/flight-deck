import Foundation
import IntakeKit

/// grok's weekly usage, read from the log line every running grok writes — no network call.
///
/// Probed on grok 1.0.30 (facts §6): after each turn grok logs to `$GROK_HOME/logs/unified.jsonl`
/// `{"msg":"billing: fetched credits config","ctx":{"config":{"creditUsagePercent":1.0,
/// "currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","start":…,"end":…},…},
/// "subscriptionTier":"SuperGrok"}}` — the same "Weekly limit 1%" its `/usage` modal draws. The
/// newest such line is the account's reading.
///
/// **What this cannot do, stated:** read the quota while no grok runs in that home (the line is
/// only as fresh as the last turn), or see a hard rejection — grok reports one only through a
/// `StopFailure` hook this build does not install. The log is shared by every grok process in
/// the home and runs to megabytes, so only its tail is read.
enum GrokBillingSource {
    static let marker = "billing: fetched credits config"
    static let tailBytes: UInt64 = 512 * 1024

    static func logURL(home: URL) -> URL {
        home.appendingPathComponent("logs", isDirectory: true).appendingPathComponent("unified.jsonl")
    }

    /// The newest billing line in `text`, as windows; nil when there is none.
    static func windows(inLogTail text: String) -> (windows: [UsageWindow], readAt: Date?)? {
        for line in text.split(separator: "\n").reversed() where line.contains(marker) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let context = object["ctx"] as? [String: Any],
                  let config = context["config"] as? [String: Any],
                  let percent = (config["creditUsagePercent"] as? NSNumber)?.doubleValue
            else { continue }
            let period = config["currentPeriod"] as? [String: Any]
            let name = (period?["type"] as? String) == "USAGE_PERIOD_TYPE_WEEKLY" ? "weekly" : "period"
            let resets = (period?["end"] as? String).flatMap(date(from:))
            let window = UsageWindow(name: name, utilization: percent / 100, resetsAt: resets)
            return ([window], (object["ts"] as? String).flatMap(date(from:)))
        }
        return nil
    }

    /// The last `tailBytes` of the account's log, decoded leniently (a cut can land mid-
    /// character; the line it splits is the oldest one and never the one wanted).
    static func readTail(home: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: logURL(home: home)) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > tailBytes ? size - tailBytes : 0)
        guard let data = try? handle.readToEnd() else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// grok writes both `2026-10-08T02:16:17.767Z` and microsecond `+00:00` stamps; the system
    /// formatter takes at most milliseconds, so the fraction is trimmed to three digits first.
    static func date(from raw: String) -> Date? {
        var text = raw
        if let dot = text.firstIndex(of: ".") {
            let fractionStart = text.index(after: dot)
            let fractionEnd = text[fractionStart...].firstIndex(where: { !$0.isNumber }) ?? text.endIndex
            let digits = text[fractionStart..<fractionEnd]
            if digits.count > 3 {
                text.replaceSubrange(fractionStart..<fractionEnd, with: String(digits.prefix(3)))
            }
        }
        return withFraction.date(from: text) ?? plain.date(from: text)
    }

    private static let withFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}
