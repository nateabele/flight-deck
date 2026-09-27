import Foundation

/// The one setting from the operator's `~/.codex/config.toml` every headless codex run carries
/// back: `service_tier`. `HarnessCommand.codexIsolation`'s `--ignore-user-config` drops the
/// file wholesale — its MCP servers and hooks, which is the point, but also `service_tier`,
/// which on this machine is `"fast"`. Without it every round seat silently ran on the default
/// tier, slower than the user's own codex. Nothing else is read: the file also starts MCP
/// servers that write outside the sandbox, so this stays an allow-list of exactly one key.
public enum CodexUserConfig {
    /// `service_tier`'s value, or nil for a missing/unreadable file, no such key, or a value
    /// that isn't a plain identifier. A minimal line parse rather than a TOML parser: only a
    /// top-level `service_tier = "…"` (before the first `[table]` header) counts, since the
    /// same key under a table is some other setting's. The identifier check is what makes it
    /// safe to splice into `-c service_tier="<value>"` — a quote or newline can't escape it.
    public static func serviceTier(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String? {
        let file = home.appendingPathComponent(".codex", isDirectory: true).appendingPathComponent("config.toml")
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { return nil }
            guard line.hasPrefix("service_tier") else { continue }
            let rest = line.dropFirst("service_tier".count).trimmingCharacters(in: .whitespaces)
            guard rest.hasPrefix("=") else { continue }
            var value = rest.dropFirst().trimmingCharacters(in: .whitespaces)
            if let hash = value.firstIndex(of: "#") { value = String(value[..<hash]).trimmingCharacters(in: .whitespaces) }
            guard value.count >= 2, let quote = value.first, quote == "\"" || quote == "'", value.last == quote else { return nil }
            let inner = value.dropFirst().dropLast()
            guard !inner.isEmpty, inner.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }) else { return nil }
            return String(inner)
        }
        return nil
    }

    /// `-c service_tier="<value>"` when the user's config sets one, else nothing.
    static func arguments(home: URL) -> [String] {
        serviceTier(home: home).map { ["-c", "service_tier=\"\($0)\""] } ?? []
    }
}
