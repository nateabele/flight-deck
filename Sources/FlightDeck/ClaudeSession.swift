import Foundation

/// Pure rules for locating and reading a Claude Code session transcript, and for
/// building the launch command. No I/O and no state so every rule is unit-testable.
///
/// The encoding rule and the `custom-title` record shape were verified empirically
/// against the installed `claude`; see
/// `docs/superpowers/specs/2026-08-10-session-name-sync-design.md` §2.
enum ClaudeSession {
    static let maxNameLength = 120

    static var defaultProjectsRoot: URL {
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent(".claude/projects", isDirectory: true)
    }

    /// Claude encodes the cwd by replacing every non-alphanumeric character with `-`,
    /// one for one. Runs are not collapsed: `/private/tmp/x/-Users` → `-private-tmp-x--Users`.
    static func encodedProjectDirName(for workingDirectory: String) -> String {
        String(workingDirectory.map { $0.isLetter || $0.isNumber ? $0 : "-" })
    }

    static func transcriptURL(
        sessionID: UUID,
        workingDirectory: String,
        projectsRoot: URL = defaultProjectsRoot
    ) -> URL {
        projectsRoot
            .appendingPathComponent(encodedProjectDirName(for: workingDirectory), isDirectory: true)
            .appendingPathComponent("\(sessionID.uuidString.lowercased()).jsonl")
    }

    /// Returns the title when `line` is this session's rename record, else nil.
    /// Shape: `{"type":"custom-title","customTitle":"…","sessionId":"…"}`.
    static func customTitle(inLine line: String, sessionID: UUID) -> String? {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              obj["type"] as? String == "custom-title",
              let sid = obj["sessionId"] as? String,
              sid.lowercased() == sessionID.uuidString.lowercased(),
              let title = obj["customTitle"] as? String
        else { return nil }
        return title
    }

    /// Trims, strips control characters, and caps length. Returns nil when nothing usable
    /// remains, which callers treat as "revert to the previous title".
    static func sanitizedName(_ raw: String) -> String? {
        let stripped = raw.unicodeScalars
            .filter { !CharacterSet.controlCharacters.contains($0) }
            .reduce(into: "") { $0.unicodeScalars.append($1) }
        let trimmed = stripped.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(maxNameLength))
    }

    /// POSIX single-quoting: wrap in `'…'` and rewrite embedded `'` as `'\''`.
    static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// The command the shell runs at session start, binding `claude` to our UUID and title.
    static func launchCommand(sessionID: UUID, title: String) -> String {
        let name = sanitizedName(title) ?? "session"
        return "claude --session-id \(sessionID.uuidString.lowercased()) "
            + "--name \(shellQuoted(name))\n"
    }

    /// The command for a session restored from a previous app launch. Reattaches to the
    /// existing conversation, falling back to a fresh session with the same id and name
    /// when the transcript has been deleted or pruned (`--resume` exits 1 in that case).
    static func resumeCommand(sessionID: UUID, title: String) -> String {
        let id = sessionID.uuidString.lowercased()
        let name = sanitizedName(title) ?? "session"
        return "claude --resume \(id) || claude --session-id \(id) --name \(shellQuoted(name))\n"
    }
}
