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

    /// The app-managed portion of the command, always a contiguous prefix. The command
    /// field renders exactly this as its immutable region, which is what makes the
    /// locked-token UI a locked *prefix* rather than arbitrary inline tokens.
    static func lockedPrefix(sessionID: UUID, title: String) -> String {
        let name = sanitizedName(title) ?? "session"
        return "claude --session-id \(sessionID.uuidString.lowercased()) --name \(shellQuoted(name))"
    }

    /// Empty list flags are a legitimate stored state — the serializer emits them as a
    /// bare flag so the editor's round-trip holds — but a bare `--add-dir` on a real
    /// command line makes `claude` fail to start. Launching drops them; persistence keeps
    /// them.
    private static func launchable(_ flags: FlagSet) -> FlagSet {
        var launchable = flags
        launchable.values = flags.values.filter { _, value in
            if case .list(let items) = value { return !items.isEmpty }
            return true
        }
        return launchable
    }

    /// The command the shell runs at session start, binding `claude` to our UUID and title.
    /// User flags follow the app-managed ones so the prefix stays contiguous.
    static func launchCommand(
        sessionID: UUID, title: String, flags: FlagSet = FlagSet()
    ) -> String {
        let tail = ClaudeFlagSerializer.serialize(launchable(flags))
        return lockedPrefix(sessionID: sessionID, title: title)
            + (tail.isEmpty ? "" : " \(tail)") + "\n"
    }

    /// The command for a session restored from a previous app launch. Reattaches to the
    /// existing conversation, falling back to a fresh session with the same id and name
    /// when the transcript has been deleted or pruned (`--resume` exits 1 in that case).
    ///
    /// Flags are applied to **both** branches: the fallback is a real session launch, and
    /// leaving it unconfigured would silently drop every preference the moment a
    /// transcript is pruned.
    static func resumeCommand(
        sessionID: UUID, title: String, flags: FlagSet = FlagSet()
    ) -> String {
        let id = sessionID.uuidString.lowercased()
        let name = sanitizedName(title) ?? "session"
        let tail = ClaudeFlagSerializer.serialize(launchable(flags))
        let suffix = tail.isEmpty ? "" : " \(tail)"
        return "claude --resume \(id)\(suffix) "
            + "|| claude --session-id \(id) --name \(shellQuoted(name))\(suffix)\n"
    }
}
