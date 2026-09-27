import Foundation

/// The `env` block of the operator's `~/.claude/settings.json`, re-applied by hand to every
/// headless claude child. `HarnessCommand.claudeIsolation`'s `--setting-sources local` drops
/// the user settings file wholesale — its permission allows, which is the point, but also its
/// `env`, which on this machine carries `ANTHROPIC_BASE_URL` (a local proxy). A shell that
/// already exports it hides the loss; the app's launchd environment doesn't, so without this
/// a Finder-launched Flight Deck's claude seats would talk to the wrong endpoint.
public enum ClaudeUserEnv {
    /// `environment` with the settings `env` merged in underneath it: an explicit process
    /// variable wins on conflict, since the caller resolved it on purpose. A missing or
    /// malformed settings file (or a non-object `env`) contributes nothing — never a failed
    /// run. Callers apply `HarnessCommand.build`'s `unsetEnvironment` AFTER this, so the
    /// settings file can never re-introduce `CLAUDE_CODE_CHILD_SESSION`/`CLAUDECODE`.
    public static func merged(into environment: [String: String],
                              home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [String: String] {
        let file = home.appendingPathComponent(".claude", isDirectory: true).appendingPathComponent("settings.json")
        guard let data = try? Data(contentsOf: file),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let env = root["env"] as? [String: Any] else { return environment }
        var merged = environment
        for (key, value) in env where merged[key] == nil {
            // claude itself stringifies scalar env values; anything nested isn't an env var.
            switch value {
            case let s as String: merged[key] = s
            case let n as NSNumber: merged[key] = n.stringValue
            default: continue
            }
        }
        return merged
    }
}
