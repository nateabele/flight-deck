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

    /// Claude encodes the cwd per **UTF-16 code unit**, not per Unicode scalar or Swift
    /// `Character`: keep a unit only if it is ASCII alphanumeric (`0-9A-Za-z`), replace every
    /// other unit with `-`. Runs are not collapsed: `/private/tmp/x/-Users` →
    /// `-private-tmp-x--Users`.
    ///
    /// Verified against real `claude` output, including non-ASCII letters (`é`, `Ω` both become
    /// `-`, not kept — unlike Swift's Unicode-aware `isLetter`) and astral-plane characters
    /// (an emoji surrogate pair becomes **two** dashes, since each UTF-16 code unit is replaced
    /// independently). Consistent with a JavaScript `.replace(/[^a-zA-Z0-9]/g, '-')` without the
    /// `u` flag.
    static func encodedProjectDirName(for workingDirectory: String) -> String {
        let scalars: [Unicode.Scalar] = workingDirectory.utf16.map { unit in
            let isASCIIAlphanumeric = (0x30...0x39).contains(unit) // 0-9
                || (0x41...0x5A).contains(unit) // A-Z
                || (0x61...0x7A).contains(unit) // a-z
            return isASCIIAlphanumeric ? Unicode.Scalar(unit)! : "-"
        }
        return String(String.UnicodeScalarView(scalars))
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

    /// Characters stripped from a sanitized name in addition to control characters, so a
    /// name typed into the sidebar (or received from Claude) cannot act as shell syntax
    /// when injected as `/rename <name>` to a pty that has no `claude` running — an
    /// explicitly supported degradation where the text goes straight to a shell prompt.
    /// Kept minimal: only characters with special meaning to `sh`/`bash`/`zsh` are removed;
    /// ordinary punctuation people use in names is left alone.
    private static let shellMetacharacters = CharacterSet(charactersIn: ";&|`$()<>")

    /// Trims, strips control and shell-metacharacters, and caps length. Returns nil when
    /// nothing usable remains, which callers treat as "revert to the previous title".
    ///
    /// This is the *only* sanitization point: `rename` sets the stored title from this
    /// same output before injecting it, so the injected text and the stored title stay
    /// byte-identical and the loop-suppression check in `applyExternalTitle` keeps working.
    static func sanitizedName(_ raw: String) -> String? {
        let stripped = raw.unicodeScalars
            .filter { !CharacterSet.controlCharacters.contains($0) && !shellMetacharacters.contains($0) }
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

    /// One state-bearing thing that happened in the transcript.
    ///
    /// `agentFinished` is emitted for *every* tool_result, not just `Agent` ones —
    /// the record does not name the tool it answers. `TranscriptWatcher` keeps a set
    /// of outstanding `Agent` ids, so an unrelated id is a harmless no-op there and
    /// this parser stays free of cross-record state.
    enum TranscriptEvent: Equatable {
        case title(String)
        case agentStarted(String)
        case agentFinished(String)
        case turnEnded
    }

    /// Parses one JSONL line into zero or more events. A single assistant record can
    /// carry several `tool_use` blocks, hence the array.
    ///
    /// Only `custom-title` is filtered by `sessionID` (preserving `customTitle`'s
    /// existing rule). The tool records need no such filter: this file is already
    /// scoped to one session, and sub-agent records live in a separate
    /// `subagents/agent-*.jsonl` file, so only top-level agents are ever seen here.
    static func events(inLine line: String, sessionID: UUID) -> [TranscriptEvent] {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String
        else { return [] }

        switch type {
        case "custom-title":
            return customTitle(inLine: line, sessionID: sessionID).map { [.title($0)] } ?? []

        case "system":
            return obj["subtype"] as? String == "turn_duration" ? [.turnEnded] : []

        case "assistant":
            return contentBlocks(obj).compactMap { block in
                guard block["type"] as? String == "tool_use",
                      block["name"] as? String == "Agent",
                      let id = block["id"] as? String
                else { return nil }
                return .agentStarted(id)
            }

        case "user":
            return contentBlocks(obj).compactMap { block in
                guard block["type"] as? String == "tool_result",
                      let id = block["tool_use_id"] as? String
                else { return nil }
                return .agentFinished(id)
            }

        default:
            return []
        }
    }

    private static func contentBlocks(_ obj: [String: Any]) -> [[String: Any]] {
        guard let message = obj["message"] as? [String: Any],
              let content = message["content"] as? [[String: Any]]
        else { return [] }
        return content
    }
}
