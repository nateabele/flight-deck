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
        /// The `claude` process's live cwd. Rewritten in place on *any* directory change —
        /// a resume into another project's conversation, but equally an `EnterWorktree` that
        /// stays inside one project — so it is the authority on where the transcript is
        /// being written, and on nothing else. Whether the tab should also be filed
        /// somewhere new is a separate judgement `SessionStore.applyRegistry` makes.
        let cwd: String
        /// Human-readable process start time, e.g. "Mon Aug 10 15:03:38 2026". Paired with
        /// `pid` it identifies one *process*: macOS recycles pids, so a row with a familiar
        /// pid and an unfamiliar `procStart` is a different process, not a resume.
        let procStart: String

        /// `cwd` and `procStart` default to empty purely so existing test call sites that
        /// predate them keep compiling. Production values always come from `decode`, which
        /// requires both.
        init(
            pid: pid_t,
            sessionID: UUID,
            activity: SessionActivity,
            waitingFor: String?,
            startedAt: Double,
            cwd: String = "",
            procStart: String = ""
        ) {
            self.pid = pid
            self.sessionID = sessionID
            self.activity = activity
            self.waitingFor = waitingFor
            self.startedAt = startedAt
            self.cwd = cwd
            self.procStart = procStart
        }
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
              let activity = SessionActivity(rawValue: rawStatus),
              let cwd = obj["cwd"] as? String,
              let procStart = obj["procStart"] as? String
        else { return nil }

        return Entry(
            pid: expectedPID,
            sessionID: sessionID,
            activity: activity,
            waitingFor: obj["waitingFor"] as? String,
            startedAt: (obj["startedAt"] as? Double) ?? 0,
            cwd: cwd,
            procStart: procStart
        )
    }
}
