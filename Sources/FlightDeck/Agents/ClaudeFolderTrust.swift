import Foundation
import IntakeKit

/// Whether a claude account has already said yes to a folder, read from its own config.
///
/// claude records folder trust per account — `projects[<path>].hasTrustDialogAccepted` in
/// `<home>/.claude.json` — so a folder trusted under one login is asked about again under every
/// other. Flight Deck carries the decision across by **answering the trust screen**, never by
/// writing the file: every running `claude` on that account holds the config in memory and
/// rewrites it whole, so an outside write is one save away from being lost, or from clobbering
/// theirs. Answering lets claude record the trust itself, the same way a click would.
///
/// Read only, and fails closed: an unreadable or unparseable config trusts nothing.
enum ClaudeFolderTrust {
    /// Whether the config at `config` trusts exactly `folder`.
    ///
    /// **The folder itself, never a folder above it**, though claude's own check walks up. A
    /// yes to `~/Projects` given under one login is a much wider grant than the question this
    /// screen asks, and carrying it to another login is a decision nobody made there.
    static func trusts(_ folder: String, configAt config: URL) -> Bool {
        guard let data = try? Data(contentsOf: config),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let projects = root["projects"] as? [String: Any],
              // The folder exactly as claude drew it, which is the key it writes. Not
              // `standardizedFileURL`: that drops `/private` from `/private/tmp/…`, and the key
              // claude wrote for the same folder keeps it.
              let entry = projects[folder] as? [String: Any]
        else { return false }
        return entry["hasTrustDialogAccepted"] as? Bool == true
    }

    /// The configs a claude account home stands for: `<home>/.claude.json`, plus `~/.claude.json`
    /// for the built-in home — which is where a `claude` started outside Flight Deck, with no
    /// `CLAUDE_CONFIG_DIR`, keeps that same account's config.
    static func configs(forHome home: URL, builtInHome: URL = AgentID.claude.builtInHome) -> [URL] {
        var configs = [home.appendingPathComponent(".claude.json")]
        if home.standardizedFileURL == builtInHome.standardizedFileURL {
            configs.append(home.deletingLastPathComponent().appendingPathComponent(".claude.json"))
        }
        return configs
    }

    /// Whether any of `homes` trusts `folder`.
    static func anyTrusts(_ folder: String, homes: [URL]) -> Bool {
        homes.contains { home in configs(forHome: home).contains { trusts(folder, configAt: $0) } }
    }
}
