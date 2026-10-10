import Foundation
import IntakeKit

/// agy's quota, read without spending a token.
///
/// `agy -p "/usage" --output-format json` answers a slash command headlessly: rc 0, ~6 s, zero
/// tokens, no conversation created (agy-tui-facts §6, re-run 2026-10-08). Its
/// `command.data.groups` carry one group per model family, each with a weekly and a 5-hour
/// bucket as `remaining_fraction` plus a UTC `reset_time`.
///
/// **Only the "Gemini Models" group is read.** agy also meters "Claude and GPT models" (the
/// third-party models it serves) in a separate group, but a gemini tab only ever launches a
/// Gemini model (`GeminiAdapter.model(for:)`), so that group is not this account's capacity for
/// anything Flight Deck runs as gemini.
///
/// **Never run against a signed-out agy.** A signed-out `agy -p` opens a Google sign-in in the
/// browser instead of failing (`GeminiProfile.signInCheck`), so every read is preceded by
/// `agy models`, the profile's own read-only sign-in check, and stops when it does not pass.
enum GeminiUsageSource {
    /// Quota moves slowly next to a tab's turn, and each read is two process spawns.
    static let pollInterval: TimeInterval = 300

    static let usageArguments = ["-p", "/usage", "--output-format", "json"]

    /// The Gemini group's buckets as windows: `gemini-5h`, `gemini-weekly`, utilization =
    /// 1 − remaining. nil when the JSON is not a usage answer at all.
    static func windows(fromUsageJSON data: Data) -> [UsageWindow]? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let command = root["command"] as? [String: Any],
              let payload = command["data"] as? [String: Any],
              let groups = payload["groups"] as? [[String: Any]]
        else { return nil }
        let formatter = ISO8601DateFormatter()
        return groups.filter { ($0["name"] as? String)?.hasPrefix("Gemini") == true }
            .flatMap { ($0["buckets"] as? [[String: Any]]) ?? [] }
            .compactMap { bucket in
                guard let id = bucket["id"] as? String,
                      let remaining = (bucket["remaining_fraction"] as? NSNumber)?.doubleValue
                else { return nil }
                return UsageWindow(name: id, utilization: max(0, 1 - remaining),
                                   resetsAt: (bucket["reset_time"] as? String).flatMap(formatter.date(from:)))
            }
    }

    /// The raw usage JSON, or nil when agy is missing, signed out, or did not answer. Blocking:
    /// call it off the main actor.
    static func read(path: String?, probe: SignInProbe = .system) -> Data? {
        guard let executable = (path ?? "").split(separator: ":").lazy.map({ "\($0)/agy" })
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) })
        else { return nil }
        let check = GeminiProfile().signInCheck
        guard let signIn = probe.run(executable, check.arguments, path ?? ""),
              check.readiness(signIn) == .ready,
              let usage = probe.run(executable, usageArguments, path ?? ""), usage.exitCode == 0
        else { return nil }
        return Data(usage.stdout.utf8)
    }
}
