import Foundation

/// Strips the two secrets a cloud machine is handed from any text about it before that text
/// leaves the service: a Tailscale auth key (`tskey-…`) and the enrollment secret (64 hex
/// characters, and any longer hex run). Both ride in the user-data OpenTofu applies, so a
/// failed apply's diagnostics can quote them, and a boot console can echo them; unredacted,
/// they would land in `infra.json`, a notification, the control socket and the CLI's stderr.
enum SecretRedaction {
    private static let patterns: [NSRegularExpression] = [
        // Keys mint as `tskey-auth-<id>-<secret>`; every kind shares the prefix.
        try! NSRegularExpression(pattern: "tskey-[A-Za-z0-9-]+"),
        try! NSRegularExpression(pattern: "[0-9A-Fa-f]{64,}"),
    ]

    static func redact(_ text: String) -> String {
        patterns.reduce(text) { text, pattern in
            pattern.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "[redacted]")
        }
    }
}
