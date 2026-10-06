import Foundation

/// Flight Deck's claude status line: how a claude tab is told to run the bundled
/// `scripts/statusline.sh`, and which status line of the user's that script must keep drawing.
///
/// Why a status line: Flight Control's usage meter needs each account's rate-limit windows, and
/// the status line's stdin is the one place claude hands them to an outside command — no hook
/// payload carries them. It replaced a Claude Code mod (`session.measure`), which the engine
/// could switch off remotely and so could blank every claude meter at once with nothing on this
/// side to notice.
///
/// Claude takes one status line, so ours must wrap the user's: the wrapper records usage and
/// pipes the same stdin to the user's command, whose output goes to claude unchanged.
enum ClaudeStatusLine {
    /// The user's own status line command, set in a claude tab's environment at launch.
    static let userCommandVariable = "FLIGHT_DECK_USER_STATUSLINE"
    /// Relative to the plugin root.
    static let scriptPath = "scripts/statusline.sh"
    /// Seconds. A status line otherwise runs only on activity; the timer also lets an idle tab's
    /// status line keep time-based text current. The wrapper writes nothing when the reading has
    /// not moved, so a tick costs one short process tree per tab, not a meter update.
    static let refreshInterval = 30

    /// The parts of the user's `statusLine` setting that Flight Deck carries over.
    struct User: Equatable {
        var command: String
        var padding: Int?
        var hideVimModeIndicator: Bool?
        var refreshInterval: Int?
    }

    /// The status line the user would see without Flight Deck, from the same sources claude
    /// reads and in claude's precedence order: a `--settings` flag the user set, then the
    /// project's `.claude/settings.local.json`, then its `.claude/settings.json`, then the
    /// account's `settings.json` (`CLAUDE_CONFIG_DIR`, or `~/.claude`). Managed settings outrank
    /// all of these and `--settings` too; under them our status line does not run at all.
    ///
    /// A source whose status line is our own wrapper is skipped rather than returned: running the
    /// wrapper as its own "user command" would recurse once per refresh until claude killed it.
    static func user(flags: FlagSet, configHome: URL, projectDirectory: URL,
                     home: String = NSHomeDirectory()) -> User? {
        var sources: [[String: Any]?] = []
        if case .value(let raw)? = flags.values["--settings"] {
            sources.append(settingsObject(flagValue: raw, projectDirectory: projectDirectory, home: home))
        }
        let project = projectDirectory.appendingPathComponent(".claude", isDirectory: true)
        sources.append(jsonObject(at: project.appendingPathComponent("settings.local.json")))
        sources.append(jsonObject(at: project.appendingPathComponent("settings.json")))
        sources.append(jsonObject(at: configHome.appendingPathComponent("settings.json")))
        for case let settings? in sources {
            guard let line = settings["statusLine"] as? [String: Any],
                  (line["type"] as? String ?? "command") == "command",
                  let command = line["command"] as? String,
                  !command.trimmingCharacters(in: .whitespaces).isEmpty,
                  !isOurs(command) else { continue }
            return User(command: expandingTilde(command, home: home),
                        padding: (line["padding"] as? NSNumber)?.intValue,
                        hideVimModeIndicator: (line["hideVimModeIndicator"] as? NSNumber)?.boolValue,
                        refreshInterval: (line["refreshInterval"] as? NSNumber)?.intValue)
        }
        return nil
    }

    /// Sets `--settings` to carry our status line. A `--settings` the user already passed is
    /// merged into, never replaced: their other settings keep applying, and their status line
    /// (if any) is what `user(...)` hands the wrapper to run. A path value is read and folded in
    /// inline, because claude takes one `--settings` and a second one would drop the first.
    ///
    /// When the user's value cannot be read as a JSON object — a missing file, bad JSON — the
    /// flags are returned unchanged: claude would refuse that value anyway, and its error is the
    /// user's to see. Replacing it would hide their mistake behind our working status line.
    static func injecting(into flags: FlagSet, wrapper: URL, user: User?, projectDirectory: URL?,
                          home: String = NSHomeDirectory()) -> FlagSet {
        var settings: [String: Any] = [:]
        if case .value(let raw)? = flags.values["--settings"] {
            guard let existing = settingsObject(flagValue: raw, projectDirectory: projectDirectory, home: home) else {
                return flags
            }
            settings = existing
        }
        var line: [String: Any] = [
            "type": "command",
            "command": ClaudeSession.shellQuoted(wrapper.path),
            // The user's own interval when it is shorter: they chose it for their text.
            "refreshInterval": min(user?.refreshInterval ?? refreshInterval, refreshInterval),
        ]
        if let padding = user?.padding { line["padding"] = padding }
        if let hide = user?.hideVimModeIndicator { line["hideVimModeIndicator"] = hide }
        settings["statusLine"] = line
        // `.withoutEscapingSlashes`: the value is typed into the tab's shell, and under fish a
        // backslash inside single quotes is an escape character. Every path has slashes, so
        // JSONSerialization's default `\/` would put a backslash in every launch line.
        guard let data = try? JSONSerialization.data(withJSONObject: settings, options: [.sortedKeys, .withoutEscapingSlashes]),
              let json = String(data: data, encoding: .utf8) else { return flags }
        var out = flags
        out.values["--settings"] = .value(json)
        return out
    }

    /// Our wrapper, by either of the two places it ships: the copy under Application Support and
    /// the app bundle. Both paths contain "Flight Deck"; a user's own `statusline.sh` does not.
    static func isOurs(_ command: String) -> Bool {
        command.contains("Flight Deck") && command.contains(scriptPath)
    }

    /// `~/x` → `'<home>'/x`. Quoted rather than spliced in raw, so a home with a space still runs
    /// as one word through the wrapper's `sh -c`.
    static func expandingTilde(_ command: String, home: String) -> String {
        guard command.hasPrefix("~/") else { return command }
        return ClaudeSession.shellQuoted(home) + command.dropFirst(1)
    }

    /// `--settings` takes inline JSON or a path, like claude's own reading of it. A relative
    /// path is the project's, which is where claude starts.
    private static func settingsObject(flagValue raw: String, projectDirectory: URL?, home: String) -> [String: Any]? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{") {
            return (try? JSONSerialization.jsonObject(with: Data(trimmed.utf8))) as? [String: Any]
        }
        var path = trimmed
        if path == "~" || path.hasPrefix("~/") { path = home + path.dropFirst(1) }
        let url = path.hasPrefix("/") || projectDirectory == nil
            ? URL(fileURLWithPath: path)
            : projectDirectory!.appendingPathComponent(path)
        return jsonObject(at: url)
    }

    private static func jsonObject(at url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
