import Foundation

/// Pure decoding of one `~/.claude/sessions/<pid>.json` registry file. No I/O and no
/// state, so every rule is unit-testable.
///
/// The registry is undocumented and unversioned. Every parse rule here fails closed:
/// anything unrecognized yields nil, and the caller keeps its last known status rather
/// than showing a guess. See the design spec §1 for the field shapes and §10 for the
/// risk this mitigates.
enum ClaudeStatusFile {
    struct Entry: Equatable {
        let pid: pid_t
        let sessionID: UUID
        let activity: SessionActivity
        let waitingFor: String?
        /// Epoch milliseconds. Breaks ties when two files claim one session (crash,
        /// then resume): the newest wins.
        let startedAt: Double
    }

    /// Parses "<pid>.json". Rejects anything that does not round-trip back to the same
    /// digits, which is what `claude`'s own reader does before unlinking the file.
    static func pid(fromFileName name: String) -> pid_t? {
        guard name.hasSuffix(".json") else { return nil }
        let stem = String(name.dropLast(5))
        guard let value = Int32(stem), String(value) == stem, value > 0 else { return nil }
        return value
    }

    /// `expectedPID` is the pid parsed from the filename; a mismatch means a stale or
    /// hand-edited file.
    static func decode(_ data: Data, expectedPID: pid_t) -> Entry? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawPID = obj["pid"] as? Int,
              let pid = pid_t(exactly: rawPID), pid == expectedPID,
              let rawSession = obj["sessionId"] as? String,
              let sessionID = UUID(uuidString: rawSession),
              let rawStatus = obj["status"] as? String,
              let activity = SessionActivity(rawValue: rawStatus)
        else { return nil }

        return Entry(
            pid: expectedPID,
            sessionID: sessionID,
            activity: activity,
            waitingFor: obj["waitingFor"] as? String,
            startedAt: (obj["startedAt"] as? Double) ?? 0
        )
    }
}
