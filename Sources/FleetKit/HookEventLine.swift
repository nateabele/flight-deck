import CryptoKit
import Foundation

/// One line of the Claude hook event log (`hook-events-<tag>/events.ndjson`), as written and
/// as read.
///
/// **Written pared, never verbatim.** Claude Code hands each hook its whole payload:
/// `UserPromptSubmit` carries the prompt, `PreToolUse` the tool's full input, and `PostToolUse`
/// its full output — file contents, command output, whatever a tool returned. `record.sh` used
/// to append all of it, so the log grew by megabytes a minute (3.5 GB by 2026-10-31) and kept
/// every prompt and every tool result in plain text, forever. Flight Deck reads exactly the
/// fields in `keptKeys`, plus `tool_input` for one purpose: `DialogAttribution` matches a
/// `PermissionRequest` to the `PreToolUse` with the *same* input. Equality needs no content,
/// so the input travels as a digest.
///
/// **One digest definition for both sides.** The writer (`flightdeck hook-record`) and the
/// reader (`HookEventRecord.decode`) both call `toolInputDigest(in:)`, so a line written by
/// this build and a legacy line still carrying a raw `tool_input` (a hook that ran under an
/// older plugin) digest to the same value.
public enum HookEventLine {
    public static let fileName = "events.ndjson"

    /// The payload fields copied through as-is. Everything else is dropped.
    public static let keptKeys = ["session_id", "hook_event_name", "agent_id", "tool_use_id", "tool_name"]

    /// The key the pared line carries the input digest under.
    public static let digestKey = "tool_input_digest"

    /// The pared line for one hook payload, newline-terminated, or nil when the payload is not
    /// a JSON object naming a session and an event (nothing the reader could use).
    public static func pare(_ payload: Data) -> Data? {
        guard let obj = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              obj["session_id"] is String, obj["hook_event_name"] is String
        else { return nil }
        var kept: [String: Any] = [:]
        for key in keptKeys { if let value = obj[key] as? String { kept[key] = value } }
        if let digest = toolInputDigest(in: obj) { kept[digestKey] = digest }
        guard var line = try? JSONSerialization.data(withJSONObject: kept, options: [.sortedKeys])
        else { return nil }
        line.append(UInt8(ascii: "\n"))
        return line
    }

    /// The input digest a line stands for: the pared line's own, or one computed from a legacy
    /// line's raw `tool_input`. Canonical JSON (keys sorted) hashed with SHA-256, so the same
    /// input compares equal however Claude happened to order its keys.
    public static func toolInputDigest(in obj: [String: Any]) -> String? {
        if let digest = obj[digestKey] as? String { return digest }
        guard let input = obj["tool_input"],
              let canonical = try? JSONSerialization.data(
                  withJSONObject: input, options: [.sortedKeys, .fragmentsAllowed])
        else { return nil }
        return SHA256.hash(data: canonical).map { String(format: "%02x", $0) }.joined()
    }

    /// Appends one line to `directory/events.ndjson` with a single `write(2)` on an
    /// `O_APPEND` descriptor, creating the file owner-only. Opened per line and closed at once,
    /// which is what lets the reader rotate the file out from under writers: a writer holds
    /// the old file for microseconds, then the next one creates a fresh one.
    @discardableResult
    public static func append(_ line: Data, toDirectory directory: URL) -> Bool {
        let path = directory.appendingPathComponent(fileName).path
        let fd = open(path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        return line.withUnsafeBytes { bytes in
            write(fd, bytes.baseAddress, bytes.count) == bytes.count
        }
    }
}
