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
        /// Whether the registry reported a background task running under this agent.
        ///
        /// The **observation**, not a conclusion. Claude Code can only report this while the
        /// session is idle — it writes `"shell"` for `idle && hasBackgroundTasks` and plain
        /// `busy`/`waiting` otherwise — so `false` here means *not reported*, never *known
        /// absent*. `SessionStore` owns turning these observations into durable state.
        let reportsBackgroundWork: Bool

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
            procStart: String = "",
            reportsBackgroundWork: Bool = false
        ) {
            self.pid = pid
            self.sessionID = sessionID
            self.activity = activity
            self.waitingFor = waitingFor
            self.startedAt = startedAt
            self.cwd = cwd
            self.procStart = procStart
            self.reportsBackgroundWork = reportsBackgroundWork
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
              let cwd = obj["cwd"] as? String,
              let procStart = obj["procStart"] as? String
        else { return nil }

        // `"shell"` is not a fourth activity: Claude Code writes it for `idle &&
        // hasBackgroundTasks` and reports the two facts through one field. Split here so
        // nothing downstream has to know the encoding — and note the asymmetry, which is
        // upstream's and not ours: during a turn it reports `busy` and drops the background
        // fact entirely, so `false` below is "not reported", not "no background work".
        let activity: SessionActivity
        let reportsBackgroundWork: Bool
        if rawStatus == "shell" {
            activity = .idle
            reportsBackgroundWork = true
        } else {
            guard let parsed = SessionActivity(rawValue: rawStatus) else { return nil }
            activity = parsed
            reportsBackgroundWork = false
        }

        return Entry(
            pid: expectedPID,
            sessionID: sessionID,
            activity: activity,
            waitingFor: obj["waitingFor"] as? String,
            startedAt: (obj["startedAt"] as? Double) ?? 0,
            cwd: cwd,
            procStart: procStart,
            reportsBackgroundWork: reportsBackgroundWork
        )
    }
}
